#!/usr/bin/env bash
# grill-visual のサーバーを止める。使い方: stop.sh <session_dir>
# 一時ディレクトリのセッションは消し、--project-dir のセッション(.grill-visual/ 内)は画面を残す。
set -u

session="${1:-}"
[ -n "$session" ] && [ -d "$session/state" ] || { echo '{"error": "usage: stop.sh <session_dir>"}'; exit 1; }
session="$(cd "$session" && pwd)"

pid=""
if [ -s "$session/state/server-info" ]; then
  pid="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$session/state/server-info" | head -n 1)"
fi

# 別のプロセスに pid が再利用されていたら止めない
if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q 'serve\.cjs'; then
  kill "$pid" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then echo '{"error": "サーバーが止まりませんでした"}'; exit 1; fi
fi

case "$session" in
  */grill-visual-*) rm -rf "$session"; echo '{"status": "stopped"}' ;;
  *) echo '{"status": "stopped", "kept": true}' ;;
esac
