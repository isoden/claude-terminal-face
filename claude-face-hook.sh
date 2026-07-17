#!/usr/bin/env bash
# ============================================================================
#  claude-face-hook.sh — Claude Code hooks → claude-terminal-face-status.glsl 状態連携
#
#  Claude Code の hook イベント（PreToolUse/PostToolUse/UserPromptSubmit/Stop）
#  を受け取り、作業状態(idle/thinking/working/done/err)を OSC 12（カーソル色
#  設定エスケープシーケンス）でシェーダー側に伝える。spec.md §9 参照。
#
#  2026-07-12: hook の stdout は Claude Code 側が JSON パース用に pipe で
#  読み取っており、端末には届かない。/dev/tty に直接書き込む必要がある
#  （cli.js の spawn 実装をもとに確認済み）。
#
#  settings.json 登録例は spec.md §9 参照。stdin には hook の JSON payload
#  が渡ってくる前提。
# ============================================================================
set -euo pipefail

# 2026-07-13: Claude Code hooks は spawn() の子プロセスとして起動され、
# 制御端末を継承しない（/dev/tty が ENXIO で開けない。herdr の有無を問わず
# 発生することを実機確認済み）。そのため祖先プロセスを遡って実際の TTY
# （例: ttys011）を特定し、そのデバイスファイルに直接書き込む。
#
# herdr（ターミナルマルチプレクサ）配下では、各 pane が内部で独自の仮想
# 端末（libghostty-vt）を持つだけで OS レベルの制御端末を割り当てないため、
# 祖先探索が「たまたま見つかった無関係な別セッションの TTY」に書き込んで
# しまう恐れがある（実機確認済み、spec.md §9.8 参照）。祖先に herdr が
# いたら安全側に倒して諦める。
find_tty() {
  local p="$PPID" t cmd
  for _ in 1 2 3 4 5 6 7 8; do
    [ -n "$p" ] && [ "$p" != "0" ] || return 1
    cmd="$(ps -o command= -p "$p" 2>/dev/null)"
    case "$cmd" in *herdr*) return 1 ;; esac
    t="$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')"
    if [ -n "$t" ] && [ "$t" != "??" ] && [ -w "/dev/$t" ] 2>/dev/null; then
      echo "/dev/$t"
      return 0
    fi
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}

TTY="$(find_tty)" || exit 0

json="$(cat)"

# agent_id を持つイベントは Task 経由のサブエージェント発火なので無視する。
# ~/.claude/hooks/herdr-agent-state.sh と同じガードパターン。
agent_id="$(jq -r '.agent_id // empty' <<<"$json" 2>/dev/null || true)"
[ -z "$agent_id" ] || exit 0

event="$(jq -r '.hook_event_name // empty' <<<"$json" 2>/dev/null || true)"

THINK=f0c14b
WORK=3d6fe0
DONE=8bd346
ERR=ff5f6d

send() { { printf '\e]12;#%s\a' "$1" > "$TTY"; } 2>/dev/null || true; }

case "$event" in
  UserPromptSubmit)
    send "$THINK"
    ;;
  PreToolUse)
    tool="$(jq -r '.tool_name // empty' <<<"$json" 2>/dev/null || true)"
    case "$tool" in
      Read|Grep|Glob|WebSearch|WebFetch|Task|TodoWrite) send "$THINK" ;;
      Edit|Write|Bash|NotebookEdit|MultiEdit)           send "$WORK"  ;;
    esac
    ;;
  PostToolUse)
    # tool_response に汎用の exit code フィールドは無い。Claude Code が
    # Bash 実行を失敗判定した場合のみ stderr 末尾に "Exit code {n}" という
    # 文字列が付与される（cli.js 実装確認、2026-07-12）。settings.json 側で
    # matcher=Bash に絞って登録する前提。
    stderr="$(jq -r '.tool_response.stderr // empty' <<<"$json" 2>/dev/null || true)"
    if grep -qE 'Exit code [0-9]+' <<<"$stderr"; then
      send "$ERR"
    else
      send "$WORK"
    fi
    ;;
  Stop)
    send "$DONE"
    ;;
esac

exit 0
