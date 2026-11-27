#!/usr/bin/env bash
# courier が送信の一時的な失敗を再試行し、配送の結果を wait_for_report.sh の通知に載せることを確認する。
# 送信は偽の tmux_send.sh で失敗させる（2026-10-05 実測: 起動元 pane へ tmux が「not in a mode」を返し、
# 1 回の失敗で .undeliverable になって [報告] が届かなかった）。
set -euo pipefail

source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d /tmp/agent-orchestrate-courier-retry.XXXXXX)
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
  local source="$1/$2"
  cp "$source" "$runtime_dir/$2"
}
for name in deliver_report.sh report_route.sh mark_report_done.sh wait_for_report.sh; do
  copy_script "$source_dir/scripts" "$name"
done

# 最初の fail_count 回は tmux と同じ文言で失敗し、それ以降は本物の tmux へ送る偽の sender
cat >"$sender_dir/tmux_send.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
pane="$1"; shift; msg="$*"
count_file="$(dirname "$0")/attempts"
attempts=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$attempts" >"$count_file"
if (( attempts <= $(cat "$(dirname "$0")/fail_count") )); then
  echo "not in a mode" >&2
  exit 1
fi
tmux send-keys -t "$pane" -l -- "$msg"
tmux send-keys -t "$pane" Enter
EOF
chmod +x "$runtime_dir"/*.sh "$sender_dir"/*.sh

origin=$(tmux new-window -d -P -F '#{pane_id}' -n courier-retry-origin zsh)
worker=$(tmux new-window -d -P -F '#{pane_id}' -n courier-retry-worker zsh)
sleep 1

# 1 回の courier を走らせ、wait_for_report.sh の出力を返す
run_case() {
  local name="$1" fail_count="$2"
  local report_file="$test_dir/$name-report.md" route_file="$test_dir/$name-route"
  echo "$fail_count" >"$sender_dir/fail_count"
  rm -f "$sender_dir/attempts"
  printf '%s\n' "# $name" >"$report_file"
  AGENTS_PLAY_CATCH_SENDER_DIR="$sender_dir" AGENTS_PLAY_CATCH_RETRY_INTERVAL_SECONDS=1 TMUX_PANE="$origin" \
    bash "$runtime_dir/report_route.sh" "$route_file" "$name" "$report_file" verifier "$worker" >/dev/null
  bash "$runtime_dir/mark_report_done.sh" "$report_file" 完了 "$name" >/dev/null 2>&1 || true
  bash "$runtime_dir/wait_for_report.sh" --i-confirmed-run-in-background-auto-resumes-my-turn "$report_file" 60
}

# 一時的な失敗は再試行して届け、通知に配送済みと出す
output=$(run_case transient 2)
[[ "$(cat "$sender_dir/attempts")" == 3 ]] || { echo "FAIL: 3 回目で送れていない: $(cat "$sender_dir/attempts")" >&2; exit 1; }
[[ -f "$test_dir/transient-report.md.delivered" ]] || { echo "FAIL: .delivered が無い" >&2; exit 1; }
[[ "$output" == *"delivery=delivered"* ]] || { echo "FAIL: 通知に delivery=delivered が無い: $output" >&2; exit 1; }

# 失敗し続ければ配送不能にし、通知と report に配送不能と pane の状態を残す
output=$(run_case persistent 99)
[[ -f "$test_dir/persistent-report.md.undeliverable" ]] || { echo "FAIL: .undeliverable が無い" >&2; exit 1; }
[[ "$output" == *"delivery=undeliverable"* ]] || { echo "FAIL: 通知に delivery=undeliverable が無い: $output" >&2; exit 1; }
grep -q "pane_in_mode=" "$test_dir/persistent-report.md" || { echo "FAIL: report に pane の状態が無い" >&2; exit 1; }
echo "ok"
