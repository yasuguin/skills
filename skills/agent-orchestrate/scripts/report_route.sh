#!/usr/bin/env bash
# 投函時点で検証した通信先を、投函ごとに一意な tmp manifest へ固定する。
# manifest は投函側と courier 専用であり、worker には渡さない。宛先情報を worker に
# 握らせると codex の approval review が exfiltration と判定して報告コマンドを拒否する
# (2026-07-17 実測)ため、worker の報告義務は report と done マーカー(<report>.done)の
# ファイル書き込みだけにする。あわせて配送用の courier (deliver_report.sh) をここで
# detach 起動し、done マーカーの検知と tmux/herdr への配送は courier が代行する
# (codex sandbox は unix socket へ connect できないので worker には配送させられない)。
set -euo pipefail
[[ $# -eq 5 ]] || { echo "usage: report_route.sh <route-file> <task-id> <report-file> <worker-role> <worker-pane-id>" >&2; exit 2; }
route_file="$1"
task_id="$2"
report_file="$3"
worker_role="$4"
worker_pane="$5"
[[ "$route_file" == /tmp/* && "$report_file" == /tmp/* ]] || { echo "error: route-file と report-file は /tmp 配下にすること" >&2; exit 1; }
[[ "$task_id" != *$'\n'* && "$task_id" != *=* ]] || { echo "error: task-id が不正" >&2; exit 1; }
[[ ! -e "$route_file" ]] || { echo "error: route-file は投函ごとに新規作成すること: $route_file" >&2; exit 1; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# worker は manifest を知らないので、signal は report パスから機械的に導ける done マーカーにする
signal_file="$report_file.done"
[[ ! -e "$signal_file" ]] || { echo "error: done マーカーが既に存在する。report パスは投函ごとに一意にすること: $signal_file" >&2; exit 1; }

write_manifest() {
  umask 077
  {
    printf 'schema=agent-orchestrate-route-v1\n'
    printf 'task_id=%s\n' "$task_id"
    printf 'transport=%s\n' "$1"
    printf 'origin=%s\n' "$2"
    printf 'worker_role=%s\n' "$worker_role"
    printf 'worker_pane=%s\n' "$worker_pane"
    printf 'reply_to=%s\n' "$2"
    printf 'report_file=%s\n' "$report_file"
    printf 'signal_file=%s\n' "$signal_file"
  } >"$route_file"
}

start_courier() {
  # tmux transport は tmux server 自身の job として起動する。macOS / WSL では
  # orchestrator のツール呼び出しが終わると、その shell が nohup + disown した
  # 子プロセスまで終了させることがあり、worker 完了前に courier が消えていた。
  if [[ -n "${TMUX:-}" ]]; then
    sender_dir="${AGENTS_PLAY_CATCH_SENDER_DIR:-$script_dir}"
    retry_interval="${AGENTS_PLAY_CATCH_RETRY_INTERVAL_SECONDS:-20}"
    printf -v courier_command 'PATH=%q HOME=%q AGENTS_PLAY_CATCH_SENDER_DIR=%q AGENTS_PLAY_CATCH_RETRY_INTERVAL_SECONDS=%q bash %q %q </dev/null >>%q 2>&1' \
      "$PATH" "$HOME" "$sender_dir" "$retry_interval" "$script_dir/deliver_report.sh" "$route_file" "$route_file.courier.log"
    tmux run-shell -b "$courier_command"
    echo "info: 報告配送 courier を tmux server job として起動した (log=$route_file.courier.log)" >&2
  # Herdr outside tmux still needs a detached process. setsid is preferred where available;
  # macOS falls back to nohup because its system utilities do not include setsid.
  elif command -v setsid >/dev/null 2>&1; then
    setsid bash "$script_dir/deliver_report.sh" "$route_file" \
      </dev/null >>"$route_file.courier.log" 2>&1 &
    disown "$!" 2>/dev/null || true
    echo "info: 報告配送 courier を起動した (pid=$!, log=$route_file.courier.log)" >&2
  else
    nohup bash "$script_dir/deliver_report.sh" "$route_file" \
      </dev/null >>"$route_file.courier.log" 2>&1 &
    disown "$!" 2>/dev/null || true
    echo "info: 報告配送 courier を起動した (pid=$!, log=$route_file.courier.log)" >&2
  fi
}

if [[ "${HERDR_ENV:-}" == "1" && -n "${HERDR_PANE_ID:-}" ]]; then
  origin="$HERDR_PANE_ID"
  [[ "$origin" =~ ^[^[:space:]:]+:p[^[:space:]:]+$ && "$worker_pane" =~ ^[^[:space:]:]+:p[^[:space:]:]+$ ]] || { echo "error: Herdr pane ID が不正" >&2; exit 1; }
  herdr pane get "$origin" >/dev/null
  herdr pane get "$worker_pane" >/dev/null
  write_manifest herdr "$origin"
  start_courier
  printf '%s\n' "$route_file"
  exit 0
fi
origin="${TMUX_PANE:-}"
[[ "$origin" == %* ]] || { echo "error: TMUX_PANE is not available" >&2; exit 1; }
tmux display-message -p -t "$origin" '#{pane_id}' >/dev/null
tmux display-message -p -t "$worker_pane" '#{pane_id}' >/dev/null
write_manifest tmux "$origin"
start_courier
printf '%s\n' "$route_file"
