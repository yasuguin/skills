#!/usr/bin/env bash
# Herdr の agent を起動し、`herdr agent start` の JSON を stdout に出す。
# usage: herdr_start_agent.sh <name> -- <command> [args...]
# 対象 repo(git の top-level、無ければ cwd)の workspace を探して再利用し、無ければ作る。
set -euo pipefail

if [[ $# -lt 3 || "$2" != "--" ]]; then
  echo "usage: herdr_start_agent.sh <name> -- <command> [args...]" >&2
  exit 2
fi
name="$1"
shift 2

server_ready() {
  herdr status server --json >/dev/null 2>&1
}

if ! server_ready; then
  herdr server >/dev/null 2>&1 &
  disown 2>/dev/null || true
  for _ in $(seq 1 50); do
    server_ready && break
    sleep 0.1
  done
  server_ready || {
    echo "Herdr server could not be started. Run 'herdr status server --json' for details." >&2
    exit 1
  }
fi

cwd=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
workspace_id=$(herdr pane list \
  | jq -r --arg cwd "$cwd" '.result.panes[]? | select(.cwd == $cwd) | .workspace_id' \
  | sort -u | head -n 1)

if [[ -z "$workspace_id" ]]; then
  workspace_result=$(herdr workspace create --cwd "$cwd" --label "$(basename "$cwd")" --no-focus)
  workspace_id=$(printf '%s' "$workspace_result" | jq -r '.result.workspace.workspace_id')
fi
if [[ -z "$workspace_id" || "$workspace_id" == "null" ]]; then
  echo "Herdr did not return a workspace for $cwd." >&2
  exit 1
fi

# agent を直接 exec すると Herdr pane の端末初期化より Codex/Claude の色判定が先行し、
# ライトモードで文字色が白になる(実測)。対話シェルを一段経由して初期化を終わらせてから起動する。
# 同じ対話シェルが rc 経由で PATH も整えるので、呼び出し側に login shell は要らない。
if command -v zsh >/dev/null 2>&1; then
  interactive_shell=zsh
else
  interactive_shell="${SHELL:-bash}"
fi

# 呼び出し側はこの JSON の pane_id を通信契約へ固定する。role 名で再検索すると
# 同名の古い agent 登録を拾うため、起動結果を捨ててはいけない。
exec herdr agent start "$name" --cwd "$cwd" --workspace "$workspace_id" --no-focus -- \
  "$interactive_shell" -ic 'exec "$@"' herdr-agent "$@"
