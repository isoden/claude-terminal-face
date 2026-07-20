#!/usr/bin/env bash
# ============================================================================
#  claude-face-ramp.sh — カーソル色を直前色 → 目標色へ RGB 直線で段階送信する
#
#  claude-terminal-face-status.glsl はステートレスで「色がいつ変わったか」を
#  知れない（Ghostty の iTimeCursorChange / iPreviousCursorColor はカーソルの
#  移動・点滅でも更新されるため、フェーズ遷移の時間軸として使えない。shader の
#  冒頭コメント参照）。そこで時間軸をこちら側で供給する: OSC 12 を短時間に
#  複数回送って直前色→目標色を線形に描き、シェーダーは各瞬間の色を状態重みへ
#  デコードするだけにする。これでフェーズ間（例: thinking→working）の顔の
#  切り替えが、フェーズ内モーフと同じように連続的に見える（2026-07-18）。
#
#  中間色が「当事者2状態だけ」に清浄にデコードされることは、キーパレットの
#  設計で保証している（misc/palette-check.mjs で検証）。
#
#  使い方: claude-face-ramp.sh <TTY> <TO_HEX>
#    TTY     書き込み先端末デバイス（例: /dev/ttys011）。同一セッションでは
#            hook と precmd が同じ実パスを渡すこと（状態ディレクトリのキーに
#            使うため。/dev/tty のような共有シンボルを渡すとセッション間で
#            状態が混線する）。
#    TO_HEX  目標のキー色（6桁16進、# なし。例: f7b81f）
#
#  直前色は状態ディレクトリに記録しており、呼び出し側は目標色だけ渡せばよい。
#
#  ---- デタッチが要（2026-07-18 実機で判明）----------------------------------
#  Claude Code は hook コマンドを実行後、その**プロセスグループごと**刈り取る。
#  そのため単に `{ ...loop... } &` + `disown` で投げただけの送信ループは、hook が
#  return した直後に SIGTERM を受けて 2〜3 ステップで死に、結局フェーズ遷移が
#  一瞬でスナップする（「変わってない」の実際の原因だった。実測で確認）。
#  disown はシェルのジョブ表から外すだけでプロセスグループは変えないため、
#  グループ宛シグナルは防げない。対策として送信ループを **新セッション**
#  （新しいプロセスグループ）で起動し、hook のグループ刈り取りから隔離する。
#  macOS には setsid バイナリが無いので、あれば setsid、無ければ perl の
#  POSIX::setsid、それも無ければ素の background にフォールバックする。
# ============================================================================
# set -e は使わない: 算術 $(( ... )) が 0 を返す・比較が偽になる等でスクリプトが
# 途中終了しやすく、ランプが尻切れになるため。個別に || true で保護する。
set -uo pipefail

# ---- 内部モード: 実際の段階送信ループ（新セッションで exec される）----------
if [ "${1:-}" = "--animate" ]; then
  tty="$2"; gen_file="$3"; mygen="$4"; from="$5"; to="$6"
  send() { printf '\e]12;#%s\a' "$1" > "$tty" 2>/dev/null || true; }

  # 直前色が不明（初回など）ならランプせず即セット。黒等からの不自然な補間を避ける。
  if [ "$from" = "-" ]; then
    send "$to"
    exit 0
  fi

  hx() { printf '%d' "0x$1" 2>/dev/null || printf 0; }
  fr=$(hx "${from:0:2}"); fg=$(hx "${from:2:2}"); fb=$(hx "${from:4:2}")
  tr=$(hx "${to:0:2}");   tg=$(hx "${to:2:2}");   tb=$(hx "${to:4:2}")

  # ---- 送信色列の生成 -------------------------------------------------------
  # 2026-07-20: 「RGB 直線を等速（+ease-in-out）で走る」旧方式をやめ、シェーダーの
  # デコード（距離二乗の softmax）を逆写像した位置に色を配る方式へ変更した。
  #
  # 旧方式が抱えていた問題: シェーダーの重みは
  #     w_to = sigmoid(K * (2s - 1)),  K = |キー色間距離|² / STATE_SOFT,  s = 線分上の位置
  # という急峻な S 字で、think→work なら K ≈ 32。w が 10%→90% に動くのは
  # s = 0.47〜0.53 のわずか 7% 区間で、ease-in-out で中盤が最速（×1.5）になることも
  # あって実効モーフ時間は ≈0.04s しかなかった。0.9s かけて送っていたのに顔（形も
  # ティントも重み由来）は一瞬でスナップし、フェーズ内モーフ（VAR_MORPH ≈0.63s）と
  # 明らかに不揃いだった。
  #
  # そこで w のほうを時間の関数として設計し、必要な s を逆算する:
  #     s = 0.5 + logit(w) / (2K)
  # w に smoothstep を与えれば、顔の形もティントも VAR_MORPH と同じ流儀
  # （0→1 を ease-in-out で線形補間）で動く。
  #
  # 構成は head → body → tail の 3 区間:
  #   body … 上式で w を 0.01→0.99 まで動かす区間（≈0.88s）。ここが実効モーフで、
  #           smoothstep の効く中央部 w=10%→90% は実測 ≈0.58s ＝ VAR_MORPH とほぼ同じ。
  #           s の可動域は 0.5 ± logit(0.99)/(2K) ≒ 0.5 ± 0.07 と線分の中央付近だけ。
  #   head/tail … body の s 範囲と実キー色との間を色だけ埋める区間。ここでは w が
  #           <1% でしか動かないので顔は変わらない。カーソル色自体はユーザーの目に
  #           見えるので、これが無いと両端で色が 43% ぶん飛んで見える。
  #
  # 制約（既知の限界）: 8bit/ch 量子化。body の s 幅 ≈0.14 に対し最大チャネル差
  # ≈0.7*255 なので、body 全体で ≈25 階調しか取れない。ステップを増やしても
  # 同色の連投になるだけなので body は 26 ステップに留める。
  #
  # sleep 値が 20ms なのは、sleep が外部コマンドで 1 ステップあたり ≈14ms の
  # spawn オーバーヘッドが乗るため（macOS 実測）。実効間隔 ≈34ms（≈30Hz）。
  head=5; body=26; tail=5

  # bash の整数演算では logit（log）が計算できないので awk で色列を一括生成する。
  # STATE_SOFT はシェーダー側の定数の写し。片方だけ変えると遷移尺が狂う
  # （spec.md §7.4 と同種の二重管理）。
  colors="$(awk -v fr="$fr" -v fg="$fg" -v fb="$fb" \
                -v tr="$tr" -v tg="$tg" -v tb="$tb" \
                -v head="$head" -v body="$body" -v tail="$tail" '
    function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v) }
    function emit(s,   r, g, b) {
      s = clamp(s, 0, 1)
      r = fr + (tr - fr) * s; g = fg + (tg - fg) * s; b = fb + (tb - fb) * s
      printf "%02x%02x%02x\n", int(r + 0.5), int(g + 0.5), int(b + 0.5)
    }
    BEGIN {
      soft = 0.03                                          # = shader の STATE_SOFT
      L2 = ((tr-fr)^2 + (tg-fg)^2 + (tb-fb)^2) / (255*255)  # キー色間の距離二乗
      K = L2 / soft
      if (K < 1e-6) K = 1e-6                               # ゼロ除算保険（同色は呼出側で弾く）
      wmin = 0.01
      sLo = clamp(0.5 + log(wmin / (1 - wmin)) / (2 * K), 0, 1)
      sHi = clamp(0.5 - log(wmin / (1 - wmin)) / (2 * K), 0, 1)

      for (i = 1; i <= head; i++) emit(sLo * i / head)      # 色だけ寄せる（顔は不変）
      for (i = 1; i <= body; i++) {                         # ここが実効モーフ
        p = i / body
        w = wmin + (1 - 2 * wmin) * (p * p * (3 - 2 * p))   # smoothstep
        emit(0.5 + log(w / (1 - w)) / (2 * K))
      }
      for (i = 1; i < tail; i++) emit(sHi + (1 - sHi) * i / tail)  # 最終ステップは呼出側が送る
    }')"

  for hex in $colors; do
    # 追い越し検知: 自分より新しい世代が記録されていたら降りる（最新の遷移だけが
    # TTY を握る）。
    [ "$(cat "$gen_file" 2>/dev/null || echo)" = "$mygen" ] || exit 0
    send "$hex"
    sleep 0.020
  done
  # 終端はキー色ちょうどに落とす（tail の丸め誤差で 1LSB ずれると、次のランプの
  # 起点色と記録色が食い違う）。
  send "$to"
  exit 0
fi

# ---- 通常エントリ: 状態更新 → アニメを新セッションで起動 --------------------
tty="${1:-}"
to="${2:-}"
[ -n "$tty" ] && [ -n "$to" ] || exit 0

# セッションごとに独立した状態ディレクトリ（TTY 実パスをキーにする）。
slug="$(printf '%s' "$tty" | tr -c 'A-Za-z0-9' '_')"
dir="${TMPDIR:-/tmp}/claude-face-$slug"
mkdir -p "$dir" 2>/dev/null || true
gen_file="$dir/gen"
col_file="$dir/color"

from="$(cat "$col_file" 2>/dev/null || true)"
[ -n "$from" ] || from="-"

# 同色（連続する同一フェーズイベント等）は無駄打ち＝チラつきになるので無視。
[ "$from" = "$to" ] && exit 0

# 世代番号を進めて記録。ランプ中に新しい遷移が来たら、古いランプは自分の世代が
# 追い越されたことを検知して自滅する。
gen=$(( $(cat "$gen_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$gen" > "$gen_file" 2>/dev/null || true
printf '%s' "$to"  > "$col_file" 2>/dev/null || true

# 自スクリプトの絶対パス（--animate で再入するため）。
case "$0" in
  /*) self="$0" ;;
  *)  self="$PWD/$0" ;;
esac

# 送信ループを新セッションで起動して hook のプロセスグループ刈り取りから隔離する。
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$self" --animate "$tty" "$gen_file" "$gen" "$from" "$to" >/dev/null 2>&1 &
elif command -v perl >/dev/null 2>&1; then
  # perl を & でフォークした子はグループリーダではないので setsid() が成功し、
  # 新セッション化してからアニメ本体を exec する。
  perl -MPOSIX -e 'POSIX::setsid() or exit 0; exec @ARGV or exit 0' \
    bash "$self" --animate "$tty" "$gen_file" "$gen" "$from" "$to" >/dev/null 2>&1 &
else
  # 最終手段: 素の background（グループ刈り取り環境では尻切れの可能性あり）。
  bash "$self" --animate "$tty" "$gen_file" "$gen" "$from" "$to" >/dev/null 2>&1 &
fi
disown 2>/dev/null || true

exit 0
