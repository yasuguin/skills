#!/bin/bash
# SessionStart: 親が終わって launchd（PPID 1）に引き取られたまま CPU を使い続けている開発用プロセスを知らせる。
# 2026-10-29、ある repo の server-boot テストが spawn した `tsx src/api/server.ts` 2 本が、テストランナーの
# 強制終了で孤児になり、ポートも待ち受けずに 7 日間 CPU 100% を使い続けた。Stop の点検は
# そのセッション中に生まれた孤児しか見ないので、作ったセッションが終わった後の孤児は誰も見ていなかった。
# ps を 1 回読むだけ（数十 ms）にして、毎ターン走る Stop には置かない。誤って止めると困るので kill はせず、
# エージェントにユーザーへの提案を促すだけにする。
set -u

STATE="${ORPHAN_NOTICE_STATE_DIR:-$HOME/.local/state/agent-doctor}"
# 累積の CPU 時間がこれを超えた孤児だけを見る。待機しているだけの常駐プロセスはほぼ増えない
LIMIT_MINUTES=10
# 同じ内容を並列のセッションごとに繰り返さない
QUIET_MINUTES=360

if [[ -n "${ORPHAN_NOTICE_PS_FILE:-}" ]]; then
  table=$(cat "$ORPHAN_NOTICE_PS_FILE")
else
  table=$(ps -axo pid=,ppid=,uid=,time=,command= 2>/dev/null) || exit 0
fi

# launchd のジョブとして動くプロセス（LaunchAgents の常駐など）は孤児ではない。KeepAlive のジョブは止めても
# 起こし直されるうえ、2026-11-11 には待ち受け中の Hermes gateway を止め忘れと誤って知らせ、止めさせてしまった
if [[ -n "${ORPHAN_NOTICE_LAUNCHD_FILE:-}" ]]; then
  jobs=$(cat "$ORPHAN_NOTICE_LAUNCHD_FILE")
else
  jobs=$(launchctl list 2>/dev/null) || jobs=""
fi
job_pids=$(awk '$1 ~ /^[0-9]+$/ { printf "%s ", $1 }' <<<"$jobs")

found=$(awk -v me="$(id -u)" -v limit="$LIMIT_MINUTES" -v jobs=" $job_pids" '
  $2 == 1 && $3 == me && index(jobs, " " $1 " ") == 0 {
    # macOS の ps の time は「分:秒.小数」、Linux は「[日-]時:分:秒」
    t = $4; days = 0
    if (index(t, "-")) { split(t, d, "-"); days = d[1]; t = d[2] }
    n = split(t, p, ":")
    minutes = (n == 2) ? p[1] + p[2] / 60 : (days * 24 + p[1]) * 60 + p[2] + p[3] / 60
    command = $0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +[^ ]+ +/, "", command)
    if (minutes >= limit && command ~ /(^|[\/ ])(node|tsx|vite|vitest|bun|deno|python3?|uv|pnpm|playwright|esbuild|next)( |$)/)
      printf "%s\t%d\t%s\n", $1, minutes, substr(command, 1, 120)
  }' <<<"$table")

[[ -n "$found" ]] || exit 0
mkdir -p "$STATE" 2>/dev/null
marker="$STATE/orphan-cpu-notified"
if [[ -n "$(find "$marker" -mmin -"$QUIET_MINUTES" 2>/dev/null)" && "$(cat "$marker")" == "$(cut -f1 <<<"$found")" ]]; then
  exit 0
fi
cut -f1 <<<"$found" >"$marker"

echo "親のセッションが終わった後も CPU を使い続けている開発用プロセスがある（テストや dev server の止め忘れの可能性が高い）。"
echo "最初の返答の最後に、ユーザーへ一覧を示し、ポートを待ち受けていない・作業中でないなら止めてよいかを聞く（自分では kill しない）:"
while IFS=$'\t' read -r pid minutes command; do
  echo "- PID ${pid}（CPU 時間 ${minutes} 分）: \`$command\`"
done <<<"$found"
echo "止めるコマンド: \`kill $(cut -f1 <<<"$found" | paste -sd' ' -)\`（SIGTERM で終わらなければ kill -9）"
