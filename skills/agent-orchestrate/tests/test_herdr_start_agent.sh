#!/usr/bin/env bash
# herdr_start_agent.sh が workspace を再利用・作成し、対話シェル経由で agent を起動することを確認する。
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/herdr_start_agent.sh"
tmp=$(mktemp -d /tmp/herdr-start-agent-test.XXXXXX)
trap 'rm -r "$tmp"' EXIT
mkdir "$tmp/bin"

cat >"$tmp/bin/git" <<'EOS'
#!/usr/bin/env bash
echo /repos/repo-a
EOS
cat >"$tmp/bin/herdr" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"$HERDR_TEST_LOG"
case "$1 $2" in
  'status server') echo '{"server":{"running":true}}' ;;
  'pane list') echo "$HERDR_TEST_PANES" ;;
  'workspace create') echo '{"result":{"workspace":{"workspace_id":"w8"}}}' ;;
  'agent start') echo '{"result":{"agent":{"pane_id":"w9:p2"}}}' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
EOS
chmod +x "$tmp/bin/git" "$tmp/bin/herdr"

run() {
  : >"$tmp/log"
  PATH="$tmp/bin:$PATH" HERDR_TEST_LOG="$tmp/log" HERDR_TEST_PANES="$1" \
    bash "$script" reviewer -- codex --flag
}
fail() { echo "FAIL: $1" >&2; echo "actual: $(cat "$tmp/log")" >&2; exit 1; }
shell=zsh; command -v zsh >/dev/null || shell="${SHELL:-bash}"
launch="$shell -ic exec \"\$@\" herdr-agent codex --flag"

out=$(run '{"result":{"panes":[{"cwd":"/repos/repo-a","workspace_id":"w7"}]}}')
[[ "$out" == '{"result":{"agent":{"pane_id":"w9:p2"}}}' ]] || fail "起動結果が stdout に出ない"
[[ "$(cat "$tmp/log")" == $'status server --json\npane list\nagent start reviewer --cwd /repos/repo-a --workspace w7 --no-focus -- '"$launch" ]] \
  || fail "既存 workspace を再利用しない"

run '{"result":{"panes":[]}}' >/dev/null
[[ "$(cat "$tmp/log")" == $'status server --json\npane list\nworkspace create --cwd /repos/repo-a --label repo-a --no-focus\nagent start reviewer --cwd /repos/repo-a --workspace w8 --no-focus -- '"$launch" ]] \
  || fail "workspace を作らない"

if bash "$script" reviewer codex 2>/dev/null; then fail "引数不正で成功した"; fi
echo ok
