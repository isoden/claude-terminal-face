# claude-terminal-face

フィクション作品に見られる「機械的なボディ + 記号化された発光顔（ドットマトリクス / ASCII）」というモチーフをターミナルで再現+Claude Codeと連携させるプロトタイプ。

<video src="https://github.com/user-attachments/assets/a902d3a1-a015-4736-8700-56b43732fc9d"></video>

## 仕組み

```
Claude Code hooks ──▶ claude-face-hook.sh ──▶ OSC 12（カーソル色） ──▶ Ghostty custom shader
```

1. **Ghostty のカスタムシェーダーで顔を描画する**。`claude-terminal-face-status.glsl` を `~/.config/ghostty/config` の `custom-shader` に指定し、ターミナル背景として ASCII 顔をレンダリングする。カスタムシェーダー（GLSL）対応のターミナル＝Ghostty が必要。
2. **Claude Code の hooks で作業状態を判定する**。`UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `Stop` イベントで `claude-face-hook.sh`（bash）が起動し、イベント内容を `thinking`（調査・プランニング中）/ `working`（実装中）/ `done`（応答完了）/ `err`（Bash 失敗）にマッピングして、状態に対応する色を **OSC 12（カーソル色変更）エスケープシーケンス**として端末に書き込む。
3. **シェーダー側はカーソル色から状態を復元する**。Ghostty のカスタムシェーダーはフレーム間で状態を持てず外部入力もほぼないため、カーソル色をサイドチャネルとして使う。シェーダーは `iCurrentCursorColor` を 5 色パレット（`idle` / `thinking` / `working` / `done` / `err`）と色距離で照合し、最も近い状態の表情アニメーションを再生する。どの色からも遠い場合（通常のテーマ既定カーソル色など）は `idle` にフォールバックする。

設計の詳細・制約は [docs/SPEC.md](docs/SPEC.md)（特に §5, §9）を参照。

## セットアップ

### 必要なもの

- [Ghostty](https://ghostty.org/) 1.2.0 以降（カスタムシェーダー対応ターミナル）
- [Claude Code](https://claude.com/claude-code)
- `jq`（hook スクリプトが JSON パースに使用）

### 1. リポジトリを clone する

```sh
git clone https://github.com/isoden/claude-terminal-face.git
```

### 2. Ghostty にシェーダーを設定する

`~/.config/ghostty/config` に追記する:

```ini
custom-shader = /path/to/claude-terminal-face/claude-terminal-face-status.glsl
custom-shader-animation = always
```

Ghostty を再起動（または設定をリロード）すると背景に顔が表示される。1.2.0 以降はシェーダーファイルの保存でホットリロードされる。

### 3. Claude Code hooks を登録する

`~/.claude/settings.json` の `hooks` に `claude-face-hook.sh` を登録する（既存の hooks がある場合は配列に追記する）:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/path/to/claude-terminal-face/claude-face-hook.sh'",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/path/to/claude-terminal-face/claude-face-hook.sh'",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/path/to/claude-terminal-face/claude-face-hook.sh'",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/path/to/claude-terminal-face/claude-face-hook.sh'",
            "timeout": 5
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/path/to/claude-terminal-face/claude-face-hook.sh'",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Ghostty 上で直接 `claude` を実行すると、作業状態に応じて表情が変化する。

### 4.（任意）シェルの exit code 連携

Claude Code 実行中以外でも、直前のコマンドの成否で表情を変えたい場合は、シェルの prompt hook から `claude-face-ramp.sh` に色を送る。zsh の例:

```zsh
_claude_terminal_face_status() {
  local st=$?
  # hook と同じ claude-face-ramp.sh に委譲する。直前色の追跡を hook と共有でき
  # （状態ディレクトリのキーが TTY の実パスなので $TTY を渡す）、idle/err への
  # 遷移もランプで滑らかになる。
  local ramp=/path/to/claude-terminal-face/claude-face-ramp.sh
  if (( st == 0 )); then "$ramp" "${TTY:-$(tty)}" 5ce0c9
  else                   "$ramp" "${TTY:-$(tty)}" e00000; fi
}
precmd_functions=(_claude_terminal_face_status $precmd_functions[@])
```

色はシェーダーのキーパレット（`IDLE_KEY` = `#5ce0c9` / `ERR_KEY` = `#e00000`）と
厳密に一致させること。ずれた色はシェーダーが別の状態と誤判定するか、未知色として
`idle` にフォールバックする。

## 制限事項

- **[herdr](https://herdr.dev/) 経由では動作しない**。herdr は各 pane を内部の仮想端末（`libghostty-vt`）でシミュレートしており、pane 内から送った OSC 12 はその内部状態を変えるだけで外側の本物の Ghostty には伝播しない。また hook スクリプトに制御端末が割り当てられず、無関係な別セッションの TTY へ誤送信する恐れがあるため、`claude-face-hook.sh` は祖先プロセスに herdr を検出すると安全側に倒して何もしない。Ghostty 上で直接 `claude` を実行するセッションでのみ動作する（詳細は SPEC.md §9.8）。

## Changelog

### 2026-07-20

- **フェーズ間のモーフィングを滑らかに**。表情の切り替わりが瞬時に飛ぶのではなく、SDF を補間しながら遷移するようになった。あわせて、カーソル色のデコードに使う状態キーと、画面に出す色味（ティント）を分離した。
- **フェーズ間のモーフィングを少し速く**。実効 ≈0.58s → ≈0.45s。フェーズ内の表情替わり（≈0.63s）よりキビキビ切り替わる。
- **`/new` などのセッション開始時に `idle` へ戻す**。`SessionStart` フックで表情をリセットするようにし、前のセッションの終了状態（`done` や `err`）を引きずらなくなった。
- **思案顔に🤔（顎に手を当てる）を追加**。`thinking` の表情バリアントが 3 → 4 になった。この表情のときだけ、要素が多くなりすぎないよう頭上の「?」を出さない。

### ファーストリリース

- Ghostty のカスタムシェーダーによる ASCII 顔の描画。
- Claude Code hooks + OSC 12（カーソル色）をサイドチャネルにした状態連携。`idle` / `thinking` / `working` / `done` / `err` の 5 状態に対応。
