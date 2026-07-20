#!/usr/bin/env node
// ============================================================================
// palette-check.mjs — 状態キーパレットの「遷移経路の健全性」検証
//
// claude-terminal-face-status.glsl は、カーソル色から 5 状態
// (idle/think/work/done/err) の重みを softmax(-distSq/STATE_SOFT) で
// デコードする。フェーズ間遷移は claude-face-hook.sh が 2 キー色間を RGB
// 直線で段階送信するため、「アニメーション対象ペアの線分上のどの点でも、
// 当事者 2 状態以外（foreign）の重みが十分小さい」ことがパレットの成立条件。
//
// 検証ポリシー（2026-07-18 パレット再設計時に確定）:
//   - hook がアニメーションする think/work/done/err 間の 6 ペア: 必須（FAIL 対象）
//   - idle が絡む 4 ペア: 参考表示のみ。idle への遷移は zsh precmd 由来の
//     即時切替で中間色が描画されないため、汚染していても実害がない。
//     特に idle–err は teal→red の直線が think/work 近傍を通るため
//     幾何的に清浄化できないことが探索で判明している（ワースト 0.998）。
//
// パレット（シェーダーの *_KEY / hook の色 / shader-preview.html）を変更する
// ときは、書き換える前にここで PASS を確認すること。
//
// 実行: node misc/palette-check.mjs   (exit 0 = PASS)
// ============================================================================

const STATE_SOFT = 0.03; // シェーダーの STATE_SOFT と揃えること

// シェーダーの IDLE_KEY/THINK_KEY/WORK_KEY/DONE_KEY/ERR_KEY と同値
// (= hook の #5ce0c9 / #f7b81f / #41419c / #0a9900 / #e00000 を /255 したもの)
const PALETTE = {
  idle:  [0x5c / 255, 0xe0 / 255, 0xc9 / 255],
  think: [0xf7 / 255, 0xb8 / 255, 0x1f / 255],
  work:  [0x41 / 255, 0x41 / 255, 0x9c / 255],
  done:  [0x0a / 255, 0x99 / 255, 0x00 / 255],
  err:   [0xe0 / 255, 0x00 / 255, 0x00 / 255],
};

// hook がアニメーションで直線補間する状態（idle は precmd 即時切替のみ）
const ANIMATED = ["think", "work", "done", "err"];

// 線分上で当事者以外の重み合計がこの値を超えたら FAIL。
// 0.05 = 遷移中に別フェーズの顔が混ざっても知覚できない、の経験的閾値。
const MAX_FOREIGN_SHARE = 0.05;

const names = Object.keys(PALETTE);
const distSq = (a, b) => a.reduce((s, v, i) => s + (v - b[i]) ** 2, 0);
const lerp = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);

function weights(c) {
  const d = names.map((n) => distSq(c, PALETTE[n]));
  const dMin = Math.min(...d);
  const w = d.map((v) => Math.exp(-(v - dMin) / STATE_SOFT));
  const sum = w.reduce((s, v) => s + v, 0);
  return Object.fromEntries(names.map((n, i) => [n, w[i] / sum]));
}

// 点 p と線分 ab の距離二乗（シェーダーの segDistSq と同じ式）
function segDistSq(p, a, b) {
  const ab = b.map((v, i) => v - a[i]);
  const ap = p.map((v, i) => v - a[i]);
  const t = Math.max(0, Math.min(1, ab.reduce((s, v, i) => s + v * ap[i], 0) / distSq(a, b)));
  return distSq(p, a.map((v, i) => v + ab[i] * t));
}

function pairWorst(A, B) {
  let worst = { share: 0, s: 0, who: "-" };
  for (let k = 0; k <= 100; k++) {
    const s = k / 100;
    const w = weights(lerp(PALETTE[A], PALETTE[B], s));
    const foreign = names.filter((n) => n !== A && n !== B);
    const share = foreign.reduce((sum, n) => sum + w[n], 0);
    if (share > worst.share) {
      worst = { share, s, who: foreign.reduce((a, b) => (w[a] > w[b] ? a : b)) };
    }
  }
  return worst;
}

let fail = 0;

console.log(`== hook 遷移線分の foreign 混入チェック (STATE_SOFT=${STATE_SOFT}, 閾値=${MAX_FOREIGN_SHARE}) ==`);
for (let i = 0; i < ANIMATED.length; i++) {
  for (let j = i + 1; j < ANIMATED.length; j++) {
    const [A, B] = [ANIMATED[i], ANIMATED[j]];
    const worst = pairWorst(A, B);
    const ok = worst.share <= MAX_FOREIGN_SHARE;
    if (!ok) fail++;
    console.log(
      `${ok ? "  ok  " : "  FAIL"} ${A}–${B}: max foreign=${worst.share.toFixed(3)}` +
        (worst.share > 0.005 ? ` (${worst.who} at s=${worst.s.toFixed(2)})` : "")
    );
  }
}

console.log("\n== idle ペア（参考。precmd 即時切替のため FAIL 対象外）==");
for (const n of ANIMATED) {
  const worst = pairWorst("idle", n);
  console.log(`        idle–${n}: max foreign=${worst.share.toFixed(3)}` +
    (worst.share > 0.005 ? ` (${worst.who})` : ""));
}

console.log("\n== アンカー静止時の純度（foreign 重み合計）==");
for (const n of names) {
  const w = weights(PALETTE[n]);
  const foreign = 1 - w[n];
  const ok = foreign <= 0.02;
  if (!ok) fail++;
  console.log(`${ok ? "  ok  " : "  FAIL"} ${n}: foreign=${foreign.toFixed(4)}`);
}

console.log("\n== gate 指標（シェーダーと同じ: 5アンカー + hook 6線分への最小距離二乗）==");
// 上段: 未知のテーマ既定カーソル色の代表例。値 > STATE_GATE_HI なら完全に
// idle フォールバック。gray/orange は hook 線分（think–work / think–err）の
// ほぼ真上に乗るため gate できない = 既知の制限（spec.md §9.4）。
// 下段: アニメーション中断→再開で通り得る内部点（hook 3状態の重心）。
// これらは gate されない（値 < STATE_GATE_LO）ことが望ましい。
const probes = {
  "white   (theme)": [1, 1, 1],
  "black   (theme)": [0, 0, 0],
  "gray    (theme)": [0.5, 0.5, 0.5],
  "orange  (theme)": [1.0, 0.55, 0.0],
  "magenta (theme)": [0.9, 0.3, 0.9],
};
for (const t of [["think", "work", "done"], ["think", "work", "err"], ["work", "done", "err"], ["think", "done", "err"]]) {
  probes[`centroid ${t.map((n) => n[0]).join("")}   `] =
    [0, 1, 2].map((i) => t.reduce((s, n) => s + PALETTE[n][i], 0) / 3);
}
const gateDistSq = (p) => {
  let m = Infinity;
  for (const n of names) m = Math.min(m, distSq(p, PALETTE[n]));
  for (let i = 0; i < ANIMATED.length; i++)
    for (let j = i + 1; j < ANIMATED.length; j++)
      m = Math.min(m, segDistSq(p, PALETTE[ANIMATED[i]], PALETTE[ANIMATED[j]]));
  return m;
};
for (const [n, c] of Object.entries(probes)) {
  console.log(`        ${n}: ${gateDistSq(c).toFixed(4)}`);
}

console.log(fail ? `\nFAIL: ${fail} 件` : "\nPASS");
process.exit(fail ? 1 : 0);
