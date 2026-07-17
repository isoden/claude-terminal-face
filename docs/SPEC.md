# spec.md — ASCII Robot Face (Web prototype → Ghostty custom shader)

## 0. これは何か

PRAGMATA の「キャビン」や Stellar Blade の D1G-g2r（ディガー）に見られる、
**機械的なボディ + 記号化された発光顔**（ドットマトリクス / ASCII）というモチーフを、

1. Web（HTML/CSS/JS）のプロトタイプ
2. Ghostty のターミナル背景（GLSL custom shader）

の 2 形態で実装したもの。本ドキュメントは実装の設計意図・制約・既知の課題を引き継ぐためのもの。

### 成果物

| ファイル                     | 役割                                                      | 状態         |
| ---------------------------- | --------------------------------------------------------- | ------------ |
| `misc/claude-terminal-face-proto.html` | Web プロトタイプ。7 表情 + 手動切替 + オート + テーマ切替 | 動作確認済み |
| `claude-terminal-face.glsl`            | Ghostty custom shader（基本版。入力時刻ベースの表情）     | 未実機検証   |
| `claude-terminal-face-status.glsl`     | 上記 + exit code 連携（カーソル色サイドチャネル）         | 未実機検証   |

**未実機検証**の 2 ファイルが最優先の作業対象。実機で動かして落ちる箇所を潰すのが次のタスク。

---

## 1. 中核となる設計判断

### 1.1 表情は「絵」ではなく SDF（符号付き距離場）で持つ

ドットパターンやスプライトで表情を持つと、表情間の遷移が離散的になりカクつく。
本実装では各表情を **距離関数** として定義し、**距離値そのものを補間**する。

```
d = mix(sdf_A(p), sdf_B(p), t)
```

これにより中間形状が自動生成され、`∩ の目 → 丸目 → 斜めスリット` が連続的にモーフする。

制約: 距離場の線形補間は厳密なシェイプモーフではないため、形状差が大きいと
中間形が「溶ける」ことがある（§7.1 参照）。

### 1.2 輝度 → ASCII ランプ

距離 `d` から輝度 `v ∈ [0,1]` を作り、文字ランプに写像する。

```
v = smoothstep(0.035, -0.015, d)          // コア（内側 = 1）
  + exp(-max(d, 0.0) * 9.0) * 0.45        // 外向きブルーム
```

輪郭がアンチエイリアスされるため、1 セル未満の動きも「文字の濃さの変化」として
現れる。これが滑らかさの正体であり、Ghostty 公式サイトの ASCII 演出と同じ原理。

ランプ（暗 → 明）:

```
" "  "."  ":"  "-"  "+"  "="  "*"  "%"  "#"  "@"     // index 0..9
```

### 1.3 目と口を別フィールドで持つ

```
d = min(eyes(p), mouth(p))
```

分離する理由は **まばたき**。まばたきは「現在の目 → 閉じ目」への部分ブレンドとして
目フィールドにのみ適用する。口はそのままなので「笑ったまま瞬きする」が成立する。

### 1.4 座標系

- 顔空間: 原点 = 顔の中心。**y は下向きが正**（画面座標に合わせる）。
- 正規化: `p = (pixel - center) / (FACE_SIZE * height)`。GLSL 側は fragCoord が
  下原点なので `p.y = -p.y` で反転している。
- パーツ配置定数:
  - `EX = 0.46`（目の左右オフセット）
  - `EY = -0.30`（目の高さ）
  - `TH = 0.052`（線の太さ）
  - 口の弧中心: smile = `(0, 0.05)`, frown = `(0, 0.78)`

**この定数群は 3 ファイルで共有されている。片方だけ変えると顔が変わるので同期すること。**

---

## 2. Web プロトタイプ (`misc/claude-terminal-face-proto.html`)

### 2.1 構成

- グリッド: `W = 60`, `H = 28` 文字。等幅フォントの字送り比 `AR = 0.6` でアスペクト補正。
- DOM: `<pre>` の中に `W * H = 1680` 個の `<span>` を初回生成。
  以降は **文字・クラスが変化したセルのみ** 更新（`prevCh` / `prevLv` でキャッシュ）。
  `innerHTML` は毎フレーム触らない。
- 色: 輝度を 5 段階のクラス `.c1`〜`.c5` に量子化。上位 2 段に `text-shadow` でグロー。
- テーマ: `data-theme="digger"` で CSS 変数を差し替え（シアン ⇄ 緑リン光）。

### 2.2 表情（7 種）

| index | name     | 目                       | 口             |
| ----- | -------- | ------------------------ | -------------- |
| 0     | smile    | 弧（∩）                  | 幅広スマイル弧 |
| 1     | idle     | 角丸ボックス             | 小スマイル弧   |
| 2     | wink     | 左 = 弧, 右 = 丸         | 中スマイル弧   |
| 3     | surprise | 大きめ丸                 | リング（o）    |
| 4     | angry    | 内側が下がる斜めスリット | フラウン弧     |
| 5     | sad      | 外側が下がる斜めスリット | 小フラウン弧   |
| 6     | sleep    | 細い水平線               | 短い横棒       |

### 2.3 演出

- 呼吸: `p.y += sin(t * 1.6) * 0.012`
- 視線追従: ポインタ位置 → 目中心を最大 ±0.07 オフセット。ばね的に補間。
- まばたき: 2.5〜6.5 秒間隔でランダム。
- ディザノイズ / 走査ムラ / 切替時のグリッチ（行単位の水平ズレ）。
- `prefers-reduced-motion: reduce` で上記の揺らぎ系を全て停止し、モーフ時間も短縮。

### 2.4 操作

キー `1`–`7` = 表情, `A` = オート循環, `T` = テーマ。ボタンにも `aria-pressed` を反映。

---

## 3. Ghostty 移植 (`claude-terminal-face.glsl` / `claude-terminal-face-status.glsl`)

### 3.1 前提と制約（重要）

Ghostty のカスタムシェーダは **Shadertoy 互換の GLSL フラグメントシェーダ**で、以下の制約がある。

- **ステートレス**。フレーム間で状態を保持できない。使えるのは組み込み uniform のみ。
- **外部テクスチャを読めない**（`custom-shader-ichannel1` 相当は存在しない）。
  → フォントアトラスが使えないため、**5×5 のビットマップ疑似フォントをシェーダに埋め込む**。
- `iChannel0` = ターミナルの描画結果。差し替え不可。
- **exit code を受け取る uniform は存在しない**。Ghostty 自身は OSC 133 で終了コードを
  知っているが、シェーダには公開されていない（§5 の回避策）。
- 利用 uniform: `iResolution`, `iTime`, `iTimeDelta`, `iChannel0`,
  `iCurrentCursor`, `iPreviousCursor`, `iTimeCursorChange`,
  `iCurrentCursorColor`, `iPreviousCursorColor`。
  ※後半 3 つはバージョン依存。コンパイルが通らない環境がありうる。
- **`fragCoord.y` は Shadertoy/OpenGL 標準規約と逆**（2026-07-12 実機確認）。
  標準規約は下原点・上向き正だが、Ghostty は上原点・下向き正。この前提を誤ると
  顔全体が上下反転する（目と口が入れ替わる）。`TOPDOWN_Y` 定数（§4）で吸収している。
  [ghostty-org/ghostty のディスカッション](https://github.com/ghostty-org/ghostty/discussions/8695)
  でも「Metal 版の Y 軸反転は暫定対応止まり」と言及されており、将来 Ghostty 側で
  標準規約に統一される可能性がある。

### 3.2 設定

```ini
# ~/.config/ghostty/config
custom-shader = ~/.config/ghostty/shaders/claude-terminal-face.glsl
custom-shader-animation = always   # true = フォーカス時のみアニメーション
```

1.2.0 以降、カスタムシェーダはホットリロード対応。

### 3.3 疑似 ASCII フォント

5×5 のビットを 25bit 整数に詰める。`bit index = row * 5 + col`（row 0 が上段）。

| index | char | bits (decimal) | 点灯数 |
| ----- | ---- | -------------- | ------ |
| 0     | ` `  | 0              | 0      |
| 1     | `.`  | 4194304        | 1      |
| 2     | `:`  | 131200         | 2      |
| 3     | `-`  | 14336          | 3      |
| 4     | `+`  | 145536         | 5      |
| 5     | `=`  | 459200         | 6      |
| 6     | `*`  | 342336         | 7      |
| 7     | `%`  | 27070835       | 13     |
| 8     | `#`  | 11512810       | 16     |
| 9     | `@`  | 33084991       | 17     |

ランプは点灯数の昇順に並べてある。**新しい文字を足す場合も点灯数順を維持すること**、
さもないと階調が非単調になり縞が出る。

抽出:

```glsl
int idx = int(4.0 - q.y) * 5 + int(q.x);   // q = floor(cellUV * 5.0)
return float((bits >> idx) & 1);
```

### 3.4 状態機械の代替（ステートレスでどう表情を変えるか）

状態を持てないので、**「最後のカーソル変化からの経過秒」→ 重み** という純関数にする。

```glsl
float since = max(iTime - iTimeCursorChange, 0.0);
float wSmile = 1.0 - smoothstep(IDLE_AT - 1.0, IDLE_AT + 1.0, since);  // 打鍵直後
float wSleep = smoothstep(SLEEP_AT - 2.0, SLEEP_AT + 2.0, since);      // 放置
float wIdle  = clamp(1.0 - wSmile - wSleep, 0.0, 1.0);
```

重みの総和が 1 になるので、SDF の重み付き平均がそのままモーフになる。

`iTimeCursorChange` は打鍵ごとに更新される（カーソル点滅では更新されない）。

### 3.5 視線

`iCurrentCursor.xy`（ピクセル）を正規化して目のオフセットに使う。
**原点の上下がバージョン/プラットフォームで異なる可能性があるため `CURSOR_Y_FLIP` で反転可能にしてある。**

### 3.6 端末文字との合成

顔は「文字の裏」に置きたいが、アルファの扱いが macOS / Linux / バージョンで揺れる
（1.1.0 でレイヤ背景色を使う実装に変わり、Metal 側では背景が完全透明になる等）。
そのため **アルファに依存しない輝度マスク**を採用している。

```glsl
float behind = clamp(1.0 - luma(term.rgb) * 1.6, 0.0, 1.0);
vec3  col    = term.rgb + face * behind;
```

本文が明るいピクセルほど顔を減衰させる。係数 `1.6` は要調整（§7.3）。

---

## 4. チューナブル定数（GLSL）

| 定数            | 既定              | 意味                                                                                                                    |
| --------------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `CELL`          | `vec2(9.0, 18.0)` | 文字セルのピクセルサイズ。**フォント設定に合わせないと端末の行とグリッドがズレる**                                      |
| `FACE_SIZE`     | `0.62`            | 画面高に対する顔の大きさ                                                                                                |
| `FACE_COL`      | シアン            | 通常時の顔色                                                                                                            |
| `ERR_COL`       | 赤                | 失敗時の顔色（status 版のみ）                                                                                           |
| `GAIN`          | `0.30`            | 顔の明るさ。可読性と直結                                                                                                |
| `GAZE`          | `0.07`            | 視線追従の強さ。0 で固定                                                                                                |
| `IDLE_AT`       | `4.0`             | SMILE → IDLE (秒)                                                                                                       |
| `SLEEP_AT`      | `22.0`            | IDLE → SLEEP (秒)                                                                                                       |
| `ERR_EASE`      | `0.35`            | 表情が崩れるまでの時間（status 版のみ）                                                                                 |
| `CURSOR_Y_FLIP` | `1.0`             | 視線の上下反転                                                                                                          |
| `NOISE`         | `0.05`            | 走査ノイズ量                                                                                                            |
| `TOPDOWN_Y`     | `1.0`             | `fragCoord.y` が上原点・下向き正なら `1.0`（Ghostty の実挙動）。Shadertoy/OpenGL 標準規約（下原点・上向き正）なら `0.0` |

---

## 5. exit code 連携（`claude-terminal-face-status.glsl`）

### 5.1 方式: カーソル色をサイドチャネルにする

シェーダに終了コードは渡らない。そこで **OSC 12（カーソル色設定）** を経路に使う。

- シェル: プロンプト描画時に `$status` を色に符号化して OSC 12 を送る。
- シェーダ: `iCurrentCursorColor` の赤みを読んで `err ∈ [0,1]` を作り、SAD フィールドへ補間。

```glsl
float ease = smoothstep(0.0, ERR_EASE, since);
vec3  cc   = mix(iPreviousCursorColor.rgb, iCurrentCursorColor.rgb, ease);
float err  = smoothstep(0.10, 0.35, cc.r - max(cc.g, cc.b));
```

`iPreviousCursorColor` → `iCurrentCursorColor` を `iTimeCursorChange` 起点でイージング
することで、色の瞬間的な切替を表情の滑らかな崩れに変換している。

### 5.2 シェル側（fish）

```fish
function fish_prompt
    set -l st $status                       # 必ず最初に捕まえる

    if test $st -eq 0
        printf '\e]12;#5adcc6\a'            # ok
    else
        printf '\e]12;#ff5f6d\a'            # err
    end

    # …既存のプロンプト描画…
end
```

zsh は `precmd`、bash は `PROMPT_COMMAND` に同等の `printf` を置く。
カーソル色のリセットは `printf '\e]112\a'`。

### 5.3 この方式の限界

- **カーソル色を占有する**（失敗時にカーソルが赤くなる。副作用としては許容範囲）。
- **実質 1 ビット**。exit 1 / 130 / 137 を区別できない。
- 元のカーソル色が赤系だと誤爆する。**判定色を専用値に固定して色距離で判定する方が堅い**（未実装、§8）。
- `iPreviousCursorColor` / `iTimeCursorChange` はバージョン依存。

### 5.4 却下した代替案（再検討する場合の記録）

1. **画面ピクセルのスクレイプ**: プロンプトが固定位置に色ブロックを 1 文字描き、
   シェーダが `iChannel0` のその座標をサンプルする。色数を増やせば exit code を
   そのまま符号化できるが、スクロール・リサイズ・全画面 TUI で容易に壊れる。
2. **TUI 常駐プロセス**: 顔を tmux / zellij のペインで動くプログラムとして実装し、
   `fish_postexec` から FIFO で `$status` を送る。構造的にはこれが正しく、exit code も
   コマンド名も所要時間も渡せる。ただし「背景」ではなく「ペイン」になるため、
   当初のモチーフ（背景に顔がいる）からは外れる。

---

## 6. 次のタスク（優先度順）

1. **実機での GLSL コンパイル検証**（macOS / Metal, Linux / OpenGL 両方）。
   - `iPreviousCursorColor` / `iTimeCursorChange` が未定義の環境ではコンパイルが落ちる。
     その場合はフォールバック（イージング無しの即時切替）に分岐できるよう、
     定数フラグで切り替えられる構成にする。
   - 整数ビット演算 `>>` / `&` が通ることの確認。通らない場合は float 演算での
     ビット抽出（`mod(floor(x / 2^i), 2.0)`）へ書き換える。
   - ✅ 2026-07-12: macOS 実機で顔が上下反転する不具合を確認・修正済み（§3.1 参照、
     `TOPDOWN_Y` 定数を追加）。WebGL でフラグメントの `fragCoord.y` を反転させて
     Ghostty の挙動を再現し、修正版で正しい向きに戻ることを確認した。
     ただし実際の Ghostty 上での再確認はまだ。**次にやるべきこと**: 修正版を
     実機の Ghostty に反映して向き・視線追従（§8 チェックリスト）を再検証する。
2. **`CELL` の自動導出**。現状ハードコード。端末の実セルサイズとズレると ASCII グリッドが
   端末の行と揃わず違和感が出る。`iResolution` から推定はできないため、
   フォント設定に応じた値を README 化するか、設定手順に組み込む。
3. **可読性の実測**。`GAIN` と `behind` の係数 `1.6` を、実際の配色（テーマ）で調整。
   本文が読みにくくなったら本末転倒。
4. **GPU 負荷の測定**。パススルーだけのシェーダでも複数ウィンドウで GPU 使用率が
   顕著に上がるという報告がある。`custom-shader-animation = always` は特に重い。
   バッテリー運用時のフォールバック（`true`）を推奨値としてドキュメント化する。

---

## 7. 既知の課題

### 7.1 SDF 線形補間の中間形

距離場の lerp は厳密なシェイプモーフではないため、形状差が大きい表情間
（例: `surprise` の大きい丸目 ⇄ `angry` の斜めスリット）で中間形が溶ける。

**改善案**: 表情を SDF プリミティブの**パラメータ配列**（中心・半径・回転・太さ・角度）
として保持し、パラメータ側を補間する。プリミティブの種類が揃っていれば「意味のある変形」になる。
Web 版・GLSL 版の両方で同じリファクタが必要。

### 7.2 まばたきの周期性

GLSL 版は `fract(iTime * 0.19)` によるガウシアンパルスで、完全に周期的。
ステートレスなのでランダム化には `hash(floor(iTime / period))` 等で
周期ごとにジッタを与える必要がある。

**2026-07-14: `claude-terminal-face-status.glsl` のみ実装済み。** 周期番号を seed にした
`hash()` で発生タイミングを周期内 0.45〜0.87 の範囲で揺らし、エンベロープも
対称ガウシアンから「閉じ 0.10s / 開き 0.24s」の非対称に変更した（まぶたの
随意収縮は速く弛緩は遅い）。`claude-terminal-face.glsl` は未対応のまま。

### 7.3 アルファ合成の環境差

macOS / Linux とバージョンで背景アルファの意味が変わる。現状は輝度マスクで回避しているが、
テーマによっては顔が濃すぎる / 見えないことがある。`behind` の係数が唯一のつまみ。

### 7.4 Web 版と GLSL 版でパーツ定義が二重管理

`EX` / `EY` / `TH` および各パーツの SDF が JS と GLSL に重複している。
片方の調整がもう片方に反映されない。**単一の定義から生成する**か、
少なくとも定数ブロックを見比べやすい形に揃えること。

---

## 8. 検証チェックリスト

- [ ] `claude-terminal-face.glsl` が macOS でコンパイル・描画される
- [ ] `claude-terminal-face.glsl` が Linux でコンパイル・描画される
- [ ] 打鍵 → SMILE、放置 → IDLE → SLEEP が意図した秒数で遷移する
- [ ] 視線がカーソルを追う（上下が逆でない）
- [ ] `claude-terminal-face-status.glsl` で `false` 実行 → SAD にモーフし、`true` 実行 → 復帰する
- [ ] 通常のカーソル色（正常時）で `err` が誤発火しない
- [ ] 本文テキストが読める（`GAIN` 調整後）
- [ ] ASCII グリッドが端末の行と揃っている（`CELL` 調整後）
- [ ] GPU 使用率が許容範囲（アイドル時 / タイピング時）
- [ ] （§9）Claude Code 起動 → プロンプト送信で THINK 色/顔に変化する
- [ ] （§9）Read/Grep 系ツールで THINK 継続、Edit/Bash で WORK に変化する
- [ ] （§9）応答完了（Stop）で DONE（ドヤ顔）になり、次のプロンプト送信で THINK に戻る
- [ ] （§9）失敗コマンド実行 → `PostToolUse` 経由で ERR 顔になる
- [ ] （§9）`Task` でサブエージェントを起動しても、トップレベルの顔がチラつかない（`agent_id` ガード）
- [ ] （§9）`claude` 終了後、zsh の `precmd` 経由で ERR/IDLE 復帰が機能する

---

## 9. Claude Code 連携（hooks 経由の状態拡張）

### 9.1 概要

`claude-terminal-face-status.glsl` の「exit code 連携」（§5）を一般化し、Claude Code の作業状態
（調査/プランニング中・実装中・完了）も同じ「カーソル色サイドチャネル」で表す。
「直前コマンド失敗」も含めて **1 つの状態 enum** として扱う。

```
idle | thinking | working | done | err
```

| enum       | 表情                                                  | 発生源                                                         |
| ---------- | ----------------------------------------------------- | -------------------------------------------------------------- |
| `idle`     | 既存の SMILE/IDLE/SLEEP（打鍵からの経過秒で自動遷移） | 既定値・シェル `precmd`（成功時）                              |
| `thinking` | 考える顔（視線が斜め上、口を閉じる）＋頭上に「?」が浮かび周期的に左右へスライド | Claude Code hooks（調査/プランニング中）                       |
| `working`  | 集中顔（目を細める、口は真一文字）＋こめかみから汗の粒が飛び散る | Claude Code hooks（実装中）                                    |
| `done`     | ドヤ顔（片目を細める＋口角を大きく上げる）＋ウィンクに同期して目尻にキラキラ | Claude Code hooks（応答完了）                                  |
| `err`      | 困り顔（既存の SAD を踏襲）                           | Claude Code hooks（Bash 失敗）／シェル `precmd`（`$status`≠0） |

「行き詰まり」の自動検出は今回はやらない。exit code 失敗（`err`）を広義の「困り」として
代用している。

### 9.2 hooks ⇔ 状態のマッピング

| enum       | hook イベント                   | 判定条件                                                         |
| ---------- | ------------------------------- | ---------------------------------------------------------------- |
| `thinking` | `UserPromptSubmit`              | 常に                                                             |
| `thinking` | `PreToolUse`                    | `tool_name` ∈ `Read/Grep/Glob/WebSearch/WebFetch/Task/TodoWrite` |
| `working`  | `PreToolUse`                    | `tool_name` ∈ `Edit/Write/Bash/NotebookEdit/MultiEdit`           |
| `working`  | `PostToolUse`（matcher=`Bash`） | 下記の失敗判定にマッチしない場合                                 |
| `err`      | `PostToolUse`（matcher=`Bash`） | `tool_response.stderr` が `Exit code [0-9]+` にマッチ            |
| `done`     | `Stop`                          | `agent_id` なし（サブエージェント除外）                          |
| —          | 全イベント                      | `agent_id` を持つ場合は即無視（`Task` サブエージェント発火）     |

**実装済みの hook イベント一覧（2026-07-12, CLI `2.1.207` で確認）**:
`PreToolUse / PostToolUse / Notification / UserPromptSubmit / SessionStart / SessionEnd /
Stop / SubagentStop / PreCompact`。`PostToolUseFailure` という名前のイベントは存在しない
（当初の想定が誤っていた）。失敗判定は `PostToolUse`(matcher=`Bash`) の中で行う。

`agent_id` を持つイベントを無視するガードは `~/.claude/hooks/herdr-agent-state.sh`
（既存の別ツール `herdr` の統合スクリプト）と同じパターン。

### 9.3 実装上の落とし穴（要注意）

1. **hook の stdout は端末に届かない。** hook は Claude Code 側が JSON パース用に pipe
   で読み取っており、`printf '\e]12;...'` を stdout に書いても Ghostty には表示されない。
   **`/dev/tty` に書き込む必要がある**。
   さらに、`/dev/tty` が開けない環境でのエラーメッセージ抑制は
   `{ printf ... > "$TTY"; } 2>/dev/null` のように **ブロック全体を `2>/dev/null` で
   囲む**必要がある。単に `printf ... > "$TTY" 2>/dev/null` と書くと、シェルによる
   リダイレクト先オープン自体の失敗（`Device not configured` 等）は `2>/dev/null` の
   対象にならず、素通しでエラーが出る。

   **2026-07-13 追記・訂正**: 「`/dev/tty` は常に呼び出しプロセスの制御端末を指す」という
   前提は誤りだった。実機検証の結果、Claude Code hooks は `spawn()` の子プロセスとして
   起動され、**制御端末を継承しない**（`/dev/tty` が `ENXIO`/`Device not configured` で
   開けない）ことが判明した。herdr の有無を問わず発生する（Claude Code 自体の
   `spawn()` 実装に起因、herdr は無関係）。
   対策として、祖先プロセスを `ps -o ppid=`/`ps -o tty=` で遡り、`tty` 列が `??` でない
   最初の祖先の TTY（例: `ttys011`）を `/dev/ttysNNN` として直接使う（`claude-face-hook.sh`
   の `find_tty()` 参照）。herdr を使わない直接セッションではこれで正しく機能する
   （§9.8 も参照。herdr 配下は別の問題があり対象外）。

2. **`tool_response` に汎用の数値 exit code フィールドは無い。** Bash 実行が
   失敗判定された場合のみ、`tool_response.stderr` の末尾に文字列 `"Exit code {n}"` が
   付与される（cli.js の実装で確認、2026-07-12）。この文字列マッチングは Claude Code
   の内部実装に依存するヒューリスティックであり、将来のアップデートで文言が変わると
   静かに壊れる可能性がある。

3. **OSC 12 は「持続する」端末状態であり、瞬間イベントではない。** 次に誰かが新しい色を
   送るまで保持され続けるため、`done`/`err` の表示時間をタイマーで管理する必要はない。
   `thinking`/`working`/`done` は「次の状態遷移まで」自然に維持される。

4. **`claude` 実行中と zsh `precmd` は時間的に排他。** `claude` はフォアグラウンドで
   prompt サイクルをブロックするため、セッション中は外側シェルの `precmd` が発火しない。
   hooks 由来の状態（`claude` 実行中）と `precmd` 由来の状態（`claude` 実行後）は
   同じカーソル色チャンネルを取り合わない。

5. **手動シェルでの動作確認は `precmd` に上書きされる。** ターミナル上で手動で
   `printf '\e]12;...'` を打って色の変化を確認しようとすると、コマンド実行後に
   §9.6 の `precmd` が発火し、その `printf` 自体の終了コード（通常 0=成功）に応じて
   即座に idle 色で上書きしてしまう。動作確認は実際に `claude` を動かして行うこと。

6. **（2026-07-13 実機確認）Ghostty のカーソル点滅が `iTimeCursorChange` を
   誤ってリセットし続けることがある。** 点滅（blink）のたびに「カーソルが変化した」と
   判定され、`since = iTime - iTimeCursorChange` が常に小さい値に戻ってしまい、
   時間経過による表情遷移（SMILE→IDLE→SLEEP）が起こらなくなる。Ghostty 設定に
   `cursor-style-blink = false` を追加することで解消することを確認した
   （因果関係の完全な特定はできていないが、設定変更前後で症状が変わった）。

### 9.4 カーソル色パレットと距離ベース判定

5色を RGB 空間で離散配置し、シェーダー側は現在のカーソル色から**最も近いパレット色**を
距離二乗ベースで判定する（既存の「赤みだけを見る1次元判定」の一般化）。

| state    | hex       | 定数名（GLSL）         |
| -------- | --------- | ---------------------- |
| idle     | `#5adcc6` | `FACE_COL`（既存踏襲） |
| thinking | `#f0c14b` | `THINK_COL`            |
| working  | `#3d6fe0` | `WORK_COL`             |
| done     | `#8bd346` | `DONE_COL`             |
| err      | `#ff5f6d` | `ERR_COL`（既存踏襲）  |

5色間の最小ペア距離二乗は約 `0.16`（`THINK_COL`⇄`DONE_COL` 間）。`STATE_GATE_HI`（既定
`0.08`）はこれより十分小さく、パレット間の通常の遷移中に誤って `idle` へフォールバック
しないようにしてある。5色いずれからも遠い場合（未知のテーマ既定カーソル色等）は
`STATE_GATE_LO`〜`STATE_GATE_HI` の範囲で `idle` に滑らかにフォールバックする。

シェーダー側は `misc/shader-preview.html` の `prev state` / `current state` セレクタで、
任意の2状態間の遷移（イージング中の中間色）を確認できる。

### 9.5 hooks スクリプトと登録

`claude-face-hook.sh`（リポジトリ直下）が stdin の hook JSON を `jq` でパースし、
上記マッピングに従って `/dev/tty` に OSC 12 を送る。

`~/.claude/settings.json`（グローバル）に以下を登録する（グローバル設定の変更は
影響範囲が大きいため、実際の適用はユーザーの明示的な承認を得てから行うこと）:

```jsonc
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash '~/path/to/claude-terminal-face/claude-face-hook.sh'",
            "timeout": 5,
          },
        ],
      },
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash '~/path/to/claude-terminal-face/claude-face-hook.sh'",
            "timeout": 5,
          },
        ],
      },
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash '~/path/to/claude-terminal-face/claude-face-hook.sh'",
            "timeout": 5,
          },
        ],
      },
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          /* 既存の Stop フックがあればそのまま残し、配列にこのエントリを追記する */
          {
            "type": "command",
            "command": "bash '~/path/to/claude-terminal-face/claude-face-hook.sh'",
            "timeout": 5,
          },
        ],
      },
    ],
  },
}
```

`PreToolUse` は分類ロジックをスクリプト内に集約するため matcher を `*` にし、
`tool_name` の絞り込みは `jq` 側で行う（設定の二重管理を避ける）。`PostToolUse` だけは
呼び出し回数を減らすため matcher を `Bash` に限定する。

### 9.6 zsh 側（exit code 連携の実配線）

既存の exit code 連携（§5）は fish 例として書かれていたのみで、このユーザー環境の zsh
では未配線だった。`~/.config/zsh/prompt.zsh`（dotfiles リポジトリ）に `precmd` 関数を
追加して実配線した:

```zsh
_claude_terminal_face_status() {
  local st=$?
  if (( st == 0 )); then printf '\e]12;#5adcc6\a'; else printf '\e]12;#ff5f6d\a'; fi
}
precmd_functions=(_claude_terminal_face_status $precmd_functions[@])
```

### 9.7 スコープ外

Web 版（`misc/claude-terminal-face-proto.html`）への同様の連携は今回のスコープ外。Web/GLSL 版のパーツ定義
二重管理という既知の課題（§7.4）を今回のスコープでさらに悪化させるだけになるため、
対応する場合は §7.4 の統一的な解決（単一定義からの生成）と合わせて検討すること。

### 9.8 既知の制限: herdr 配下では機能しない

**herdr（ターミナルマルチプレクサ, https://herdr.dev/）配下で `claude` を動かしている場合、
この hooks 連携は機能しない。** 2026-07-13 に実機検証・herdr のソースコード
（https://github.com/ogulcancelik/herdr, Rust製）調査の結果、以下が判明した。

- herdr 配下では、エージェントプロセス（および `spawn()` される hook スクリプト）に
  OS レベルの制御端末が割り当てられない。`tty` コマンドが常に `not a tty` を返す。
- herdr は各 pane を内部で Ghostty 由来の端末エミュレーションライブラリ
  （`libghostty-vt`）を使って**仮想的にシミュレート**している。pane 内のプログラムが
  送る OSC 12（カーソル色）は、この内部の仮想端末状態を変えるだけで、外側の本物の
  Ghostty には一切伝播しない。
- herdr 自身（実際に Ghostty 内で動くクライアントプロセス）は `ToastDelivery::Terminal`
  設定時に外側の本物の Ghostty へ OSC 9 のデスクトップ通知を送る機能を持つが
  （`src/terminal_notify.rs`）、これはトースト通知専用で、任意のエスケープシーケンス
  （特に OSC 12 カーソル色）を送る汎用 API ではない。
- herdr の公開 CLI/ソケット API（`herdr pane` / `herdr agent` / `herdr notification` 等）
  を一通り確認したが、pane 内から外側の Ghostty へ OSC 12 を直接パススルーする機能は
  見当たらなかった。

`claude-face-hook.sh` の `find_tty()` は、herdr 配下で「たまたま見つかった無関係な
別セッションの TTY」に誤って書き込んでしまう事故を避けるため、祖先プロセスに
`herdr` を含むコマンドが見つかった時点で諦めるガードを入れている。

**結論**: herdr を使わず Ghostty 上で直接 `claude` を実行するセッションでのみこの機能は
動作する。herdr 経由のセッションでは動作しないことを制約として受け入れる
（ユーザー判断、2026-07-13）。将来 herdr が OSC パススルー機能を実装すれば
再検討の余地がある。
