#!/usr/bin/env bash
# macOS の tmux で done マーカーから [報告] 受領まで配送できることを確認する。
set -euo pipefail

source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d /tmp/agent-orchestrate-tmux-e2e.XXXXXX)
runtime_dir="$test_dir/agent-orchestrate"
sender_dir="$test_dir/sender"
origin=""
worker=""
cleanup() {
  [[ -z "$origin" ]] || tmux kill-pane -t "$origin" 2>/dev/null || true
  [[ -z "$worker" ]] || tmux kill-pane -t "$worker" 2>/dev/null || true
  rm -r "$test_dir"
}
trap cleanup EXIT

mkdir -p "$runtime_dir" "$sender_dir"
copy_script() {
  local scripts_dir="$1"
  local name="$2"
  local destination="$3"
  local source="$scripts_dir/$name"
  cp "$source" "$destination"
}
copy_script "$source_dir/scripts" deliver_report.sh "$runtime_dir/deliver_report.sh"
copy_script "$source_dir/scripts" report_route.sh "$runtime_dir/report_route.sh"
copy_script "$source_dir/scripts" mark_report_done.sh "$runtime_dir/mark_report_done.sh"
copy_script "$source_dir/scripts" tmux_send.sh "$sender_dir/tmux_send.sh"
chmod +x "$runtime_dir"/*.sh "$sender_dir"/*.sh

report_file="$test_dir/report.md"
route_file="$test_dir/route"
received_file="$test_dir/received"
origin=$(tmux new-window -d -P -F '#{pane_id}' -n agent-orchestrate-origin zsh)
worker=$(tmux new-window -d -P -F '#{pane_id}' -n agent-orchestrate-worker zsh)
tmux send-keys -t "$origin" -l -- "stty -echo; IFS= read -r line; stty echo; print -rn -- \$line > '$received_file'; sleep 30"
tmux send-keys -t "$origin" Enter
sleep 1

printf '%s\n' '# tmux E2E report' > "$report_file"
AGENTS_PLAY_CATCH_SENDER_DIR="$sender_dir" TMUX_PANE="$origin" bash "$runtime_dir/report_route.sh" "$route_file" tmux-e2e "$report_file" verifier "$worker"
bash "$runtime_dir/mark_report_done.sh" "$report_file" 完了 'tmux courier end-to-end test'
sleep 5

expected="[報告] tmux-e2e 完了 origin=$origin worker=$worker: tmux courier end-to-end test。詳細: $report_file"
[[ "$(<"$received_file")" == "$expected" ]]
