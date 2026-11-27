#!/bin/bash
# PreToolUse hook (matcher: Bash): gh の書き込み(issue・PR・release・label を作る・書き換える・閉じる)は、
# 向き先が自分の repo だと決められるときだけ通す。
#
# 2026-11-03、fork の repo(origin が自分、upstream が他人の公開 repo)で `gh issue create` を -R なしで打ち、
# 非公開の検討メモが upstream の公開 repo に issue として出た。gh は既定の repo(gh repo set-default)が無いと
# upstream の remote を選び、他人の issue は作った本人でも消せない。gh の remote の選び方は help に書かれていないので
# 当てにせず、次のどれかで向き先が決まり、その owner が gh-write-owners.txt にあるときだけ通す:
#   1. -R / --repo の明示
#   2. gh repo set-default の既定(git config remote.<name>.gh-resolved = base)
#   3. remote が 1 つだけ
# 決められない・他人の repo なら、止め方は引数で決める(ask: Claude Code、deny: Codex。validate-push.sh と同じ)。
# repo は cwd で決める。cd を挟むなど cwd で決められない書き方は、-R が無ければ止める。
# macOS 標準の bash 3.2 で動くよう、bash 4 以降の構文は使わない。

DECISION="${1:-ask}"
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
# 自分の owner（GitHub のユーザー名・組織名）を 1 行に 1 つ書く。無ければ、gh の書き込みはどれも確認に回る。
OWNERS="${GH_WRITE_OWNERS:-$HOME/.claude/gh-write-owners.txt}"

WRITE='(^|[[:space:];&|(])gh[[:space:]]+(issue|pr|release|label)[[:space:]]+(create|comment|edit|close|reopen|delete|transfer|lock|unlock|pin|unpin|merge|review|ready|upload|develop)([[:space:]]|$)'
printf '%s' "$COMMAND" | grep -Eq "$WRITE" || exit 0

slug_of_url() {
  # git@host:owner/repo.git・https://host/owner/repo・ssh://git@host/owner/repo を owner/repo にそろえる。
  printf '%s' "$1" | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#'
}

SLUG=$(printf '%s' "$COMMAND" | grep -oE '(-R|--repo)([[:space:]]+|=)[^[:space:];&|]+' | tail -n 1 | sed -E 's#^(-R|--repo)([[:space:]]+|=)##')
SLUG=$(slug_of_url "$SLUG")
HOW="-R の指定"

if [ -z "$SLUG" ] && printf '%s' "$COMMAND" | grep -Eq '^[[:space:]]*gh[[:space:]][^;&|]*$' && [ -n "$CWD" ]; then
  REMOTE=$(git -C "$CWD" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null | awk '$2 == "base" { sub(/^remote\./, "", $1); sub(/\.gh-resolved$/, "", $1); print $1; exit }')
  HOW="gh repo set-default の既定"
  if [ -z "$REMOTE" ] && [ "$(git -C "$CWD" remote 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    REMOTE=$(git -C "$CWD" remote)
    HOW="ただ 1 つの remote"
  fi
  [ -n "$REMOTE" ] && SLUG=$(slug_of_url "$(git -C "$CWD" remote get-url "$REMOTE" 2>/dev/null)")
fi

OWNER="${SLUG%%/*}"
if [ -n "$SLUG" ] && [ -f "$OWNERS" ] && grep -v '^#' "$OWNERS" | grep -Fxq -- "$OWNER"; then
  exit 0
fi

if [ -z "$SLUG" ]; then
  WHY="gh の書き込みの向き先を決められません(-R が無く、gh repo set-default の既定も無く、remote が複数あるか、cd などとつないでいます)。gh は既定が無いと upstream の remote を選びます。-R <owner>/<repo> を付けてください。"
else
  WHY="gh の書き込みの向き先 $SLUG($HOW)は自分の repo($OWNERS)ではありません。他人の repo に書いたものは消せないので、ユーザーの承認を取ってから実行します。"
fi
if [ "$DECISION" = "deny" ]; then
  WHY="$WHY 必要ならユーザーに \`! gh ...\` の実行を頼んでください。"
fi
jq -n --arg decision "$DECISION" --arg reason "$WHY" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: $decision, permissionDecisionReason: $reason}}'
exit 0
