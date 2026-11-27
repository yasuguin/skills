#!/usr/bin/env bash
# Herdr の wN:pN pane 専用。外側 tmux pane を受け付けず、transport の取り違えを止める。
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: herdr_send.sh <wN:pN> <single-line message>" >&2; exit 2; }
pane="$1"; shift; msg="$*"
[[ "$pane" =~ ^[^[:space:]:]+:p[^[:space:]:]+$ ]] || { echo "error: herdr_send.sh は Herdr pane ID (wN:pN) 専用。tmux は tmux_send.sh を使うこと。" >&2; exit 1; }
[[ "$msg" != *$'\n'* ]] || { echo "error: メッセージは1行のみ" >&2; exit 1; }
herdr pane get "$pane" >/dev/null
prefix="$(printf '%s' "${msg:0:20}" | tr -d '[:space:]')"
agent_status() { herdr pane get "$pane" | jq -r '.result.pane.agent_status // "unknown"'; }
before_status="$(agent_status)"

# 本文を再送すると、最初の ENTER だけが落ちた場合に同じ task を二重投函する。
# そのため本文は 1 回だけ入れ、確認に失敗したときは ENTER だけを 1 回再送する。
send_text() { herdr pane send-text "$pane" "$msg"; sleep 1; }
press_enter() { herdr pane send-keys "$pane" ENTER; sleep 2; }
landed() { herdr pane read "$pane" --source recent-unwrapped --lines 30 | tr -d '[:space:]' | grep -qF -- "$prefix"; }
submitted() {
  # idle な agent は、受け付けた task を処理し始めれば working へ遷移する。
  # 画面に本文が見えるだけでは入力欄に未送信で残ったケースを区別できない。
  [[ "$before_status" != "idle" ]] || [[ "$(agent_status)" == "working" ]]
}

send_text
press_enter
if ! landed || ! submitted; then
  echo "warn: 送信完了を確認できないため ENTER だけを1回再送する" >&2
  press_enter
fi
landed || { echo "error: 本文の着弾を確認できない" >&2; exit 1; }
submitted || { echo "error: idle の Herdr agent が working へ遷移せず、送信完了を確認できない" >&2; exit 1; }
echo "sent to $pane: $msg"
herdr pane read "$pane" --source recent-unwrapped --lines 10
