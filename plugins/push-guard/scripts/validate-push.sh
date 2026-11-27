#!/bin/bash
# PreToolUse hook (matcher: Bash): push を無確認で通すのは許可リストの repo と、既定ブランチ以外への push だけにする。
#
# 「push はユーザーが求めたときだけ」という決まりは prose だけでは守られない。Claude の settings の allow と
# Codex の rules は git push を repo を問わず通すので、push 先の repo(remote の URL の owner/repo)が
# push-allowlist.txt に無ければ止める。止め方は引数で決める:
#   ask  Claude Code。ユーザーの承認を求める
#   deny Codex。PreToolUse の ask は未対応(learn.chatgpt.com/docs/hooks)で、auto_review の設定では承認も AI が
#        判断するため、deny してユーザー自身に `! git push` を頼ませる
# 許可リスト外の repo でも、push 先が main・master・remote の既定ブランチのどれでもない branch だけなら通す
# (2026-11-05、ユーザーの判断「main 以外への push は許可なしで OK」)。タグ・削除・強制(+refspec)・--all・
# 値を取る option など、push 先の branch を決められない書き方は許可リスト外と同じに扱う。
# repo は git -C があればその path、無ければ cwd で決める。cd を挟むなど repo を決められない書き方は許可リスト外と同じに扱う。
# macOS 標準の bash 3.2 で動くよう、bash 4 以降の構文は使わない。

DECISION="${1:-ask}"
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
# 許可リストは 1 行に 1 つ owner/repo を書く。無ければ、既定ブランチへの push はどれも確認に回る。
ALLOWLIST="${PUSH_ALLOWLIST:-$HOME/.claude/push-allowlist.txt}"

# 引用符の中身と heredoc を除いてから push かを見る(commit メッセージの本文の語で止めていた。2026-11-15)。
# 除く処理は validate-bash.sh と同じ strip-shell-literals.pl。見つからなければ元の文字列で見る。
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
STRIP_LITERALS="$HOOK_DIR/strip-shell-literals.pl"
MATCH=$(printf '%s' "$COMMAND" | perl "$STRIP_LITERALS" 2>/dev/null) || MATCH="$COMMAND"
[ -n "$MATCH" ] || MATCH="$COMMAND"
# -C の path は引用符で囲んだもの("$(ghq root)/…" のように中に空白があるもの)も 1 語として読む。読めずに素通りしていた(2026-11-26)
printf '%s' "$MATCH" | grep -Eq '(^|[[:space:];&|(])git([[:space:]]+-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+))?[[:space:]]+push([[:space:]]|$)' || exit 0

# cd <path> && git push ... は、cd 先を repo として単独の push と同じに扱う(エージェントがよく打つ形で、
# 止めると許可リストの repo でも打ち直しになっていた。2026-11-15)。cd 先は空白を含まない 1 語だけ読む。
CD_PATH=$(printf '%s' "$COMMAND" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+)[[:space:]]*&&[[:space:]]*(git[[:space:]].*)$/\1/p')
if [ -n "$CD_PATH" ]; then
  case "$CD_PATH" in "~"|"~/"*) CD_PATH="$HOME${CD_PATH#\~}" ;; esac
  case "$CD_PATH" in /*) ;; *) CD_PATH="$CWD/$CD_PATH" ;; esac
  CWD="$CD_PATH"
  COMMAND=$(printf '%s' "$COMMAND" | sed -E 's/^[[:space:]]*cd[[:space:]]+[^[:space:];&|]+[[:space:]]*&&[[:space:]]*//')
fi

# 出力を | tail などに流す形と、2>&1・2>/dev/null の付け足しは、push 自体を変えないので外してから判定する
# (エージェントがよく打つ形で、許可リストの repo でも止めて打ち直しになっていた。2026-11-15)。|| は外さない。
COMMAND=$(printf '%s' "$COMMAND" | sed -E 's/[[:space:]]+\|[^|].*$//; s/[[:space:]]+[0-9]?>(&[0-9]|\/dev\/null)//g')

# 今の branch を $(...) で書く push(pr の references/submit.md の形)は HEAD と同じなので、HEAD に置き換えてから読む。
# ほかの $(...) は何に展開されるか分からないので、下で branch を決められない書き方として扱う。
COMMAND=$(printf '%s' "$COMMAND" | perl -pe 's/"?\$\(\s*git\s+(?:branch\s+--show-current|rev-parse\s+--abbrev-ref\s+HEAD)\s*\)"?/HEAD/g')

# -C の path を引用符で囲んだ形(空白を含む path)は、展開の無い文字列だけ読み、-C を外した git push … にそろえる。
# 展開を含むもの("$(ghq root)/…")は repo を決められないので、そのまま下の単独の判定に落ちて止まる。
QUOTED_REPO=$(printf '%s' "$COMMAND" | perl -ne 'print $2 if /^\s*git\s+-C\s+(["\x27])([^"\x27\$`\\]*)\1\s+push(\s|$)/')
if [ -n "$QUOTED_REPO" ]; then
  COMMAND=$(printf '%s' "$COMMAND" | perl -pe 's/^\s*git\s+-C\s+(["\x27])[^"\x27]*\1\s+/git /')
fi

SLUG=""
# 単独の git [-C <path>] push ... のときだけ repo を決める。
if printf '%s' "$COMMAND" | grep -Eq '^[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:];&|]+)?[[:space:]]+push([[:space:]][^;&|]*)?$'; then
  REPO=$(printf '%s' "$COMMAND" | awk '$2 == "-C" { print $3 }')
  REPO="${QUOTED_REPO:-${REPO:-$CWD}}"
  # 明示した remote があればそれ、無ければ origin。
  REMOTE=$(printf '%s' "$COMMAND" | awk '{ start = ($2 == "-C") ? 5 : 3; for (i = start; i <= NF; i++) if ($i !~ /^-/) { print $i; exit } }')
  URL=$(git -C "$REPO" remote get-url "${REMOTE:-origin}" 2>/dev/null || git -C "$REPO" remote get-url origin 2>/dev/null)
  # git@host:owner/repo.git・https://host/owner/repo・ssh://git@host/owner/repo を owner/repo にそろえる。
  SLUG=$(printf '%s' "$URL" | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')

  # push 先の branch を決め、どれも既定ブランチでなければ NON_DEFAULT=1。
  ARGS=$(printf '%s' "$COMMAND" | awk '{ start = ($2 == "-C") ? 5 : 3; for (i = start; i <= NF; i++) printf "%s ", $i }')
  set -f; set -- $ARGS; set +f
  OK=1; POS=""
  for ARG in "$@"; do
    case "$ARG" in
      *'$('*|*'`'*|*'"'*|*"'"*) OK=0 ;;
      -u|--set-upstream|-q|--quiet|-v|--verbose|--no-verify|--progress|--porcelain|-n|--dry-run) ;;
      -*) OK=0 ;;
      *) POS="$POS $ARG" ;;
    esac
  done
  set -f; set -- $POS; set +f
  [ $# -gt 0 ] && shift  # 1 つ目は remote
  CURRENT=$(git -C "$REPO" symbolic-ref --short -q HEAD 2>/dev/null)
  DEFAULT=$(git -C "$REPO" symbolic-ref --short -q "refs/remotes/${REMOTE:-origin}/HEAD" 2>/dev/null)
  DEFAULT="${DEFAULT#*/}"
  if [ $# -eq 0 ]; then
    # refspec 無しは今の branch を upstream(無ければ同名)へ送る。
    DESTS=$(git -C "$REPO" rev-parse --abbrev-ref --verify -q '@{upstream}' 2>/dev/null)
    DESTS="${DESTS#*/}"
    DESTS="${DESTS:-$CURRENT}"
    [ -n "$DESTS" ] || OK=0
  else
    DESTS="$*"
  fi
  for SPEC in $DESTS; do
    case "$SPEC" in +*|:*|*:) OK=0; continue ;; esac
    DEST="${SPEC#*:}"
    [ "$DEST" = "HEAD" ] && DEST="$CURRENT"
    case "$DEST" in
      refs/heads/*) DEST="${DEST#refs/heads/}" ;;
      refs/*|"") OK=0; continue ;;
    esac
    git -C "$REPO" show-ref -q --verify "refs/tags/$DEST" 2>/dev/null && OK=0
    case "$DEST" in main|master|"$DEFAULT") OK=0 ;; esac
  done
  [ -n "$SLUG" ] && [ "$OK" = 1 ] && exit 0
fi

# 既定ブランチの CI が赤なら、通す push に一言添える。赤の通知は Stop でしか届かないので、気づかず上に積んでいた。
# 止めないのは、赤を直す push もここを通るため。検証の CI は push で起動しない(週 1 回と手動)ので、event で絞らない。gh が遅くても push を待たせないよう 5 秒で打ち切る。
warn_if_red() {
  [ "$DECISION" = "grant" ] && [ -n "$SLUG" ] || return 0
  local runs skipped="" id
  runs=$(perl -e 'alarm 5; exec @ARGV' gh run list -R "$SLUG" --branch main --status completed --limit 10 \
    --json databaseId,workflowName,conclusion,event 2>/dev/null) || return 0
  # 週 1 回の判定ジョブ(changed)が残りを飛ばした run は success で終わるが、何も検査していない。最新の結果として
  # 数えると前の赤が見えなくなるので外す(2026-11-26)。見るのは週 1 回の success だけで、待ちが延びないよう 3 件まで
  for id in $(printf '%s' "$runs" | jq -r '[.[] | select(.event == "schedule" and .conclusion == "success") | .databaseId][:3][]' 2>/dev/null); do
    perl -e 'alarm 5; exec @ARGV' gh run view "$id" -R "$SLUG" --json jobs \
      --jq '[.jobs[] | select(.name != "changed") | .conclusion] | (length > 0 and all(. == "skipped"))' 2>/dev/null |
      grep -qx true && skipped="$skipped $id"
  done
  RED=$(printf '%s' "$runs" \
    | jq -r --arg skipped "$skipped" '($skipped | split(" ") | map(select(. != "") | tonumber)) as $s
             | [.[] | select(.databaseId as $i | ($s | index($i)) == null)]
             | reduce .[] as $run ({}; if has($run.workflowName) then . else .[$run.workflowName] = $run.conclusion end)
             | to_entries | map(select(.value == "failure") | .key) | join("、")' 2>/dev/null)
  [ -n "$RED" ] || return 0
  jq -n --arg context "$SLUG の main は CI が赤です($RED)。この push がその修正でなければ、先に赤を直してください。赤の上に積むと次の push も同じ理由で落ちます。" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $context}}'
}

# 一覧は owner/repo の完全一致か、owner/* でその持ち主の repo 全部
if [ -n "$SLUG" ] && [ -f "$ALLOWLIST" ] && grep -v '^#' "$ALLOWLIST" | grep -Fxq -e "$SLUG" -e "${SLUG%%/*}/*"; then
  warn_if_red
  exit 0
fi



TARGET="${SLUG:-push 先の repo を決められない書き方(cd などとつないでいる)}"
if [ "$DECISION" = "deny" ]; then
  REASON="$TARGET は push の許可リスト($ALLOWLIST)に無いので push しません。push が要るなら、ユーザーに \`! git push\` の実行を頼んでください。"
else
  REASON="$TARGET は push の許可リスト($ALLOWLIST)に無いので、ユーザーの承認を取ってから push します。"
fi
jq -n --arg decision "$DECISION" --arg reason "$REASON" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: $decision, permissionDecisionReason: $reason}}'
exit 0
