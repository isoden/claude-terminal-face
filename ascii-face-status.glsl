// ============================================================================
//  ascii-face.glsl — Ghostty custom shader（exit code 連携版）
//
//  端末の背後に ASCII ドット文字でロボットの顔を描く。表情は SDF の重み付き
//  補間なので、状態が変わると形状が連続的にモーフする。
//
//  表情の決まり方:
//    直近に入力あり      → SMILE
//    しばらく無操作      → IDLE
//    さらに放置          → SLEEP
//    Claude Code が調査/プランニング中 → THINK
//    Claude Code が実装（Edit/Write/Bash）中 → WORK
//    Claude Code の応答完了 → DONE
//    直前のコマンドが失敗 → ERR（困り顔）
//
//  これらはすべて同じ「カーソル色サイドチャネル」で伝える。シェーダには
//  exit code も hook イベントも直接渡らないため、外部プロセスが OSC 12 で
//  カーソル色を書き換え、こちらが iCurrentCursorColor を読む。
//
//    - シェル(zsh)の precmd: $status に応じて idle/err の色を送る
//    - claude-face-hook.sh (Claude Code hooks): thinking/working/done の色を送る
//
//  5状態は固定パレットの色として送られ、シェーダー側は現在のカーソル色に
//  最も近いパレット色を距離ベースで判定する（詳細は spec.md §9）。
//  claude 実行中は外側シェルの precmd が発火しないため、2つの発生源は
//  時間的に排他で、同じチャンネルを取り合わない。
//
//  ~/.config/ghostty/config
//    custom-shader = ~/.config/ghostty/shaders/ascii-face-status.glsl
//    custom-shader-animation = always
// ============================================================================

// ---- tunables --------------------------------------------------------------
// CELL: 文字セル（px）。フォント設定に合わせる。
// 2026-07-12: HackGen35ConsoleNF, font-size=12, Retina(2x) 環境向けに理論値で算出
//   （unitsPerEm=1024, hhea ascender-descender=1194, 半角送り幅=618 units）。
//   cell = (618/1024*12, 1194/1024*12) [pt] * 2 [Retina] ≈ (14.5, 28.0) [px]。
//   iResolution が物理 px か論理 px かはフォント/環境依存で変わるため実機で要検証。
const vec2  CELL      = vec2(14.5, 28.0);
const float FACE_SIZE = 0.62;              // 顔の大きさ（画面高に対する比）
const vec3  FACE_COL  = vec3(0.36, 0.88, 0.79); // 通常時の顔色（idle パレットアンカーも兼ねる）
const vec3  ERR_COL   = vec3(0.95, 0.36, 0.42); // 失敗時の顔色（err パレットアンカーも兼ねる）
const vec3  THINK_COL = vec3(0.94, 0.76, 0.29); // 考える顔（調査/プランニング中）
const vec3  WORK_COL  = vec3(0.24, 0.44, 0.88); // 集中顔（実装中）
const vec3  DONE_COL  = vec3(0.55, 0.83, 0.28); // ドヤ顔（完了）
const float GAIN      = 0.30;              // 明るさ。上げすぎると本文が読みにくい
const float GAZE      = 0.07;              // 視線追従の強さ（0 で固定）
const float IDLE_AT   = 4.0;               // SMILE → IDLE (秒)
const float SLEEP_AT  = 22.0;              // IDLE → SLEEP (秒)
const float ERR_EASE  = 0.35;              // 表情が崩れるまでの時間 (秒)
const float CURSOR_Y_FLIP = 1.0;           // 視線が上下逆なら -1.0
const float NOISE     = 0.05;
// ---- Claude Code 連携: 状態パレット距離判定のチューニング -----------------
// 2026-07-12: 5色パレット（idle/think/work/done/err）間の最小ペア距離二乗は
// 約 0.16（THINK_COL - DONE_COL 間）。STATE_GATE_HI はこれより十分小さい値
// にして、パレット間の通常の遷移中に誤って idle へフォールバックしないよう
// にする。spec.md §9 参照。
const float STATE_SOFT    = 0.03;  // 状態境界のシャープさ。小さいほど切替が急峻
const float STATE_GATE_LO = 0.02;  // 5色いずれからも遠い→idleへフォールバック開始（距離二乗）
const float STATE_GATE_HI = 0.08;  // 完全に idle 側へ倒れる距離二乗
// 2026-07-12 実機検証: Ghostty の fragCoord.y は Shadertoy/OpenGL 規約（下原点・上向き正）
// と逆で、上原点・下向き正。想定と逆だと顔が丸ごと上下反転する（目と口が入れ替わる）。
// 1.0 = Ghostty の実際の挙動（上原点）。将来 Ghostty 側で規約が標準化された場合は
// 0.0 に切り替える。
const float TOPDOWN_Y  = 1.0;
// ----------------------------------------------------------------------------

const float EX = 0.46;
const float EY = -0.30;
const float TH = 0.052;

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
float distSq(vec3 a, vec3 b) { vec3 d = a - b; return dot(d, d); }

// ---- SDF primitives --------------------------------------------------------
float sdBox(vec2 p, vec2 c, vec2 b, float r, float rot) {
    vec2 d = p - c;
    float s = sin(rot), co = cos(rot);
    d = vec2(d.x * co - d.y * s, d.x * s + d.y * co);
    vec2 q = abs(d) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float sdArc(vec2 p, vec2 c, float r, float th, float ac, float ap) {
    vec2 d = p - c;
    float len = length(d);
    float a = mod(atan(d.y, d.x) - ac + 3.14159265, 6.28318531) - 3.14159265;
    if (abs(a) <= ap) return abs(len - r) - th;
    vec2 e = c + vec2(cos(ac + ap), sin(ac + ap)) * r;
    vec2 f = c + vec2(cos(ac - ap), sin(ac - ap)) * r;
    return min(length(p - e), length(p - f)) - th;
}

// ---- parts -----------------------------------------------------------------
float arcEye(vec2 p, float sx, vec2 g) {
    return sdArc(p, vec2(sx * EX + g.x, EY + 0.09 + g.y), 0.155, TH, -1.5707963, 1.15);
}
float roundEye(vec2 p, float sx, vec2 g, float r) {
    return sdBox(p, vec2(sx * EX + g.x, EY + g.y), vec2(r, r * 1.05), r * 0.8, 0.0);
}
float slitEye(vec2 p, float sx, vec2 g, float rot) {  // 眉尻が下がった目
    return sdBox(p, vec2(sx * EX + g.x, EY + 0.03 + g.y), vec2(0.17, 0.035), 0.03, sx * rot);
}
float closedEye(vec2 p, float sx, vec2 g) {
    return sdBox(p, vec2(sx * EX + g.x, EY + 0.02 + g.y), vec2(0.16, 0.018), 0.018, 0.0);
}
float smileMouth(vec2 p, float w) {
    return sdArc(p, vec2(0.0, 0.05), w, TH, 1.5707963, 0.85);
}
float frownMouth(vec2 p, float w) {
    return sdArc(p, vec2(0.0, 0.78), w, TH, -1.5707963, 0.70);
}
float flatMouth(vec2 p) {
    return sdBox(p, vec2(0.02, 0.36), vec2(0.055, 0.02), 0.02, 0.0);
}

// ---- 5x5 疑似 ASCII フォント（bit index = row*5 + col, row 0 が上段）--------
int glyphBits(int i) {
    if (i == 1) return 4194304;   // .
    if (i == 2) return 131200;    // :
    if (i == 3) return 14336;     // -
    if (i == 4) return 145536;    // +
    if (i == 5) return 459200;    // =
    if (i == 6) return 342336;    // *
    if (i == 7) return 27070835;  // %
    if (i == 8) return 11512810;  // #
    if (i == 9) return 33084991;  // @
    return 0;
}
float glyphPixel(int bits, vec2 cellUV) {
    vec2 q = floor(cellUV * 5.0);
    if (q.x < 0.0 || q.x > 4.0 || q.y < 0.0 || q.y > 4.0) return 0.0;
    // TOPDOWN_Y=1: cellUV は fragCoord 由来で q.y=0 が画面の上段 → row 0 にそのまま対応。
    // TOPDOWN_Y=0（標準規約）: q.y=4 が画面の上段 → 反転して row 0 に対応させる。
    int row = TOPDOWN_Y > 0.5 ? int(q.y) : int(4.0 - q.y);
    int idx = row * 5 + int(q.x);
    return float((bits >> idx) & 1);
}

// ---- Claude Code 状態別の表情 ------------------------------------------
// 既存プリミティブのみを再利用し、隣接する既存表情（idle/angry/sad）と同じ
// family に揃えることで、SDF 線形補間の中間形が溶ける問題（spec.md §7.1）
// を避ける。
float thinkEyes(vec2 p, vec2 g) {
    vec2 gt = g + vec2(0.02, -0.05); // 考え込んで視線が斜め上に固定でずれる
    return min(roundEye(p, -1.0, gt, 0.10), roundEye(p, 1.0, gt, 0.10));
}
float thinkMouth(vec2 p) {
    return sdBox(p, vec2(0.05, 0.40), vec2(0.05, 0.018), 0.018, 0.0);
}
float workEyes(vec2 p, vec2 g) {
    return min(slitEye(p, -1.0, g, 0.15), slitEye(p, 1.0, g, 0.15));
}
float workMouth(vec2 p) {
    return sdBox(p, vec2(0.0, 0.40), vec2(0.10, 0.020), 0.02, 0.0);
}
// done 中は右目だけ周期的に「徐々に閉じる→保持→徐々に開く」ウィンクを繰り返す。
// `since`（iTimeCursorChange 基準 = 最後の打鍵からの経過秒）は使わない —
// done 中に文字を打つたびにリセットされ、打鍵のたびにウィンクが再発火してしまう
// ことを実機確認済み（2026-07-13）。ワンショット版はステートレスな Ghostty
// シェーダーに「done に切り替わった瞬間」を伝えるユニフォームが無いため実現不可
// と判断し、打鍵に左右されない iTime 基準のループへ変更した。
float doneWinkPulse(float t) {
    const float PERIOD   = 3.2; // 1周期の長さ（秒）
    const float CLOSE_AT = 0.35; // 周期内でウィンクが閉じ始めるタイミング
    const float CLOSE    = 0.35;
    const float HOLD     = 0.25;
    const float OPEN     = 0.35;
    float k = mod(t, PERIOD);
    float t0 = CLOSE_AT;
    float t1 = t0 + CLOSE;
    float t2 = t1 + HOLD;
    float t3 = t2 + OPEN;
    float closing = smoothstep(t0, t1, k);
    float opening = smoothstep(t2, t3, k);
    return clamp(closing - opening, 0.0, 1.0);
}
float doneEyes(vec2 p, vec2 g, float t) {
    float wink = doneWinkPulse(t);
    float eyeR = mix(arcEye(p, 1.0, g), slitEye(p, 1.0, g, -0.30), wink);
    return min(arcEye(p, -1.0, g), eyeR);
}
float doneMouth(vec2 p) {
    return smileMouth(p, 0.52);
}
float errEyes(vec2 p, vec2 g) {
    return min(slitEye(p, -1.0, g, -0.38), slitEye(p, 1.0, g, -0.38));
}
float errMouth(vec2 p) {
    return frownMouth(p, 0.26);
}

// ---- face ------------------------------------------------------------------
// wIdleS/wThinkS/wWorkS/wDoneS/wErrS はカーソル色から距離ベースで求めた
// Claude Code 状態の重み（合計 1）。idle バケットの中身だけは、従来通り
// 「打鍵からの経過秒」で smile/idle/sleep をさらにサブブレンドする。
float faceField(vec2 p, vec2 g, float since, float t,
                 float wIdleS, float wThinkS, float wWorkS, float wDoneS, float wErrS) {
    float wSmile = 1.0 - smoothstep(IDLE_AT - 1.0, IDLE_AT + 1.0, since);
    // 2026-07-12: SLEEP を一旦無効化（要望により）。元に戻す場合は下の行を
    // `float wSleep = smoothstep(SLEEP_AT - 2.0, SLEEP_AT + 2.0, since);` に戻す。
    float wSleep = 0.0;
    float wIdle  = clamp(1.0 - wSmile - wSleep, 0.0, 1.0);

    float eSmile = min(arcEye(p, -1.0, g), arcEye(p, 1.0, g));
    float eIdle  = min(roundEye(p, -1.0, g, 0.115), roundEye(p, 1.0, g, 0.115));
    float eSleep = min(closedEye(p, -1.0, g), closedEye(p, 1.0, g));
    float eIdleGroup = wSmile * eSmile + wIdle * eIdle + wSleep * eSleep;
    float mIdleGroup = wSmile * smileMouth(p, 0.46)
                      + wIdle  * smileMouth(p, 0.30)
                      + wSleep * flatMouth(p);

    float de = wIdleS  * eIdleGroup
             + wThinkS * thinkEyes(p, g)
             + wWorkS  * workEyes(p, g)
             + wDoneS  * doneEyes(p, g, t)
             + wErrS   * errEyes(p, g);
    float dm = wIdleS  * mIdleGroup
             + wThinkS * thinkMouth(p)
             + wWorkS  * workMouth(p)
             + wDoneS  * doneMouth(p)
             + wErrS   * errMouth(p);

    // まばたき（SLEEP 中は不要）。idle バケットの重みが小さいときに適用すると
    // 他状態の目形状へ不自然に閉じ目が混ざるため、wIdleS で減衰させる。
    float k = fract(t * 0.19);
    float blink = clamp(exp(-pow((k - 0.93) * 55.0, 2.0)), 0.0, 1.0) * (1.0 - wSleep) * wIdleS;
    de = mix(de, eSleep, blink);

    return min(de, dm);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 term = texture(iChannel0, uv);

    vec2 cellId = floor(fragCoord / CELL);
    vec2 cellUV = fract(fragCoord / CELL);
    vec2 smp    = (cellId + 0.5) * CELL;

    vec2 p = (smp - 0.5 * iResolution.xy) / (FACE_SIZE * iResolution.y);
    // TOPDOWN_Y=1（Ghostty）: fragCoord.y は既に下向き正なので反転不要。
    // TOPDOWN_Y=0（標準規約）: fragCoord.y は上向き正なので反転して下向き正にする。
    if (TOPDOWN_Y < 0.5) p.y = -p.y;
    p.y += sin(iTime * 1.6) * 0.012;

    vec2 cur = iCurrentCursor.xy / iResolution.xy - 0.5;
    cur.y *= CURSOR_Y_FLIP;
    vec2 g = clamp(cur, -0.5, 0.5) * vec2(2.0, 1.4) * GAZE;

    float since = max(iTime - iTimeCursorChange, 0.0);

    // --- サイドチャネル: カーソル色から Claude Code の状態を読む ---
    // 直前色 → 現在色をイージングし、表情変化そのものを滑らかにする
    float ease = smoothstep(0.0, ERR_EASE, since);
    vec3  cc   = mix(iPreviousCursorColor.rgb, iCurrentCursorColor.rgb, ease);

    // 5色パレットへの距離二乗から状態を分類する（既存の「赤みだけを見る
    // 1次元判定」を一般化したもの）。
    float dIdle  = distSq(cc, FACE_COL);
    float dThink = distSq(cc, THINK_COL);
    float dWork  = distSq(cc, WORK_COL);
    float dDone  = distSq(cc, DONE_COL);
    float dErr   = distSq(cc, ERR_COL);
    float dMin   = min(dIdle, min(dThink, min(dWork, min(dDone, dErr))));

    float wIdleS  = exp(-(dIdle  - dMin) / STATE_SOFT);
    float wThinkS = exp(-(dThink - dMin) / STATE_SOFT);
    float wWorkS  = exp(-(dWork  - dMin) / STATE_SOFT);
    float wDoneS  = exp(-(dDone  - dMin) / STATE_SOFT);
    float wErrS   = exp(-(dErr   - dMin) / STATE_SOFT);
    float wSum = wIdleS + wThinkS + wWorkS + wDoneS + wErrS;
    wIdleS /= wSum; wThinkS /= wSum; wWorkS /= wSum; wDoneS /= wSum; wErrS /= wSum;

    // 5色いずれからも遠い（未知のテーマ既定カーソル色等）なら idle にフォールバック
    float gate = smoothstep(STATE_GATE_LO, STATE_GATE_HI, dMin);
    wIdleS = mix(wIdleS, 1.0, gate);
    wThinkS *= (1.0 - gate); wWorkS *= (1.0 - gate); wDoneS *= (1.0 - gate); wErrS *= (1.0 - gate);

    float d = faceField(p, g, since, iTime, wIdleS, wThinkS, wWorkS, wDoneS, wErrS);

    float v = smoothstep(0.035, -0.015, d) + exp(-max(d, 0.0) * 9.0) * 0.45;
    v *= 0.94 + 0.06 * sin(iTime * 8.0 + cellId.y * 0.9);
    v += (hash(cellId + floor(iTime * 12.0)) - 0.5) * NOISE;
    v = clamp(v, 0.0, 1.0);

    int idx = int(clamp(floor(v * 10.0), 0.0, 9.0));
    if (v < 0.07) idx = 0;

    float ink = glyphPixel(glyphBits(idx), cellUV);
    vec3  tint = FACE_COL * wIdleS + THINK_COL * wThinkS + WORK_COL * wWorkS
               + DONE_COL * wDoneS + ERR_COL * wErrS;
    vec3  face = tint * ink * (0.35 + 0.65 * v) * GAIN;

    float behind = clamp(1.0 - luma(term.rgb) * 1.6, 0.0, 1.0);
    vec3  col = term.rgb + face * behind;

    fragColor = vec4(col, max(term.a, luma(face) * behind));
}
