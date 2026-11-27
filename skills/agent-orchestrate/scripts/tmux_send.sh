#!/usr/bin/env bash
# tmux の %NN pane 専用。Herdr pane を受け付けず、transport の取り違えを止める。
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: tmux_send.sh <%NN> <single-line message>" >&2; exit 2; }
pane="$1"; shift; msg="$*"
[[ "$pane" == %* ]] || { echo "error: tmux_send.sh は tmux pane ID (%NN) 専用。Herdr は herdr_send.sh を使うこと。" >&2; exit 1; }
[[ "$msg" != *$'\n'* ]] || { echo "error: メッセージは1行のみ" >&2; exit 1; }
tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null
# tmux は send-keys を受理したことまでは確認できるが、汎用的に TUI が入力を
# 受理したかを照合する状態 API を持たない。入力を受理すると本文を画面から消す
# TUI もあるため、capture-pane の本文不在を失敗として Enter を再送してはならない。
# 実際の task 完了は、報告の配送（references/delivery.md）で end-to-end に確認する。
send_text() { tmux send-keys -t "$pane" -l -- "$msg"; sleep 1; }
press_enter() { tmux send-keys -t "$pane" Enter; sleep 2; }
send_text
press_enter
echo "sent to $pane: $msg"
tmux capture-pane -p -t "$pane" | tail -10
