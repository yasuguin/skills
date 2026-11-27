#!/usr/bin/env bash
# grill-visual のサーバーを起動し、url・screen_dir・state_dir を JSON 1 行で返す。
# 使い方: start.sh [--project-dir <dir>] [--foreground] [--idle-minutes <n>]
#   --project-dir  <dir>/.grill-visual/ にセッションを置く(無ければ OS の一時ディレクトリ)
#   --foreground   サーバーを前面で動かす(裏のプロセスを回収する環境で、呼び出し側が裏に回す)
#   --idle-minutes 操作がなければ止まるまでの分(既定 240)
# 失敗したときは {"error": "..."} を返して非 0 で終わる。
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir=""
foreground=0
idle=""

fail() { printf '{"error": "%s"}\n' "$1"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir) [ $# -ge 2 ] || fail "--project-dir needs a value"; project_dir="$2"; shift 2 ;;
    --foreground) foreground=1; shift ;;
    --idle-minutes) [ $# -ge 2 ] || fail "--idle-minutes needs a value"; idle="$2"; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done

command -v node >/dev/null 2>&1 || fail "node が見つかりません"

if [ -n "$project_dir" ]; then
  [ -d "$project_dir" ] || fail "project dir が存在しません: $project_dir"
  base="$(cd "$project_dir" && pwd)/.grill-visual"
  session="$base/$$-$(date +%s)"
else
  session="${TMPDIR:-/tmp}/grill-visual-$$-$(date +%s)"
  session="${session//\/\//\/}"
fi
mkdir -p "$session/state" "$session/content" || fail "セッションの場所を作れません: $session"
log="$session/state/server.log"

# 起動元の見分け: $PPID は呼び出しのたびに使い捨てられるシェルなので、その親(エージェント本体)を見張る。
# 親を調べられないとき(ps が使えない sandbox など)は、使い捨てのシェルを誤って見張らないよう、見張りを付けない。
owner="$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')"
case "$owner" in ''|0|1) owner="" ;; esac

export GRILL_VISUAL_DIR="$session"
export GRILL_VISUAL_OWNER_PID="$owner"
[ -n "$idle" ] && export GRILL_VISUAL_IDLE_MINUTES="$idle"

if [ "$foreground" = 1 ]; then
  exec node "$here/serve.cjs"
fi

nohup node "$here/serve.cjs" >"$log" 2>&1 &
pid=$!
disown "$pid" 2>/dev/null || true

# 起動を最大 5 秒待つ。server-info は待ち受けが始まってから書かれる
for _ in $(seq 1 50); do
  if [ -s "$session/state/server-info" ]; then cat "$session/state/server-info"; exit 0; fi
  if ! kill -0 "$pid" 2>/dev/null; then
    reason="$(tail -n 1 "$log" 2>/dev/null | tr -d '"\\' | cut -c1-200)"
    fail "サーバーが起動直後に終了しました(log: $log): $reason"
  fi
  sleep 0.1
done
fail "サーバーが 5 秒以内に待ち受けを始めませんでした(log: $log)"
