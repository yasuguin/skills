#!/usr/bin/env bash
# 入力を受理すると本文を画面から消す TUI でも、tmux_send.sh が再送・失敗にしないことを確認する。
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)
test_dir=$(mktemp -d /tmp/agent-orchestrate-send-test.XXXXXX)
pane=""
cleanup() {
  [[ -z "$pane" ]] || tmux kill-pane -t "$pane" 2>/dev/null || true
  rm -r "$test_dir"
}
trap cleanup EXIT

result_file="$test_dir/received"
pane=$(tmux new-window -d -P -F '#{pane_id}' -n agent-orchestrate-send-test zsh)
tmux send-keys -t "$pane" -l -- "stty -echo; IFS= read -r line; stty echo; print -rn -- \$line > '$result_file'; sleep 30"
tmux send-keys -t "$pane" Enter
sleep 1

message='tmux-acceptance-test-7f3d'
sender="$script_dir/tmux_send.sh"
bash "$sender" "$pane" "$message"
[[ "$(<"$result_file")" == "$message" ]]
