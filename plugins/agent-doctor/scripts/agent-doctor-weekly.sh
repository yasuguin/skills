#!/bin/bash
# SessionStart: agent-doctor の集計を週 1 回自動で回し、異常があれば次のセッションで 1 回だけ知らせる。
# launchd ではなく hook にしたのは、PC が止まっていた週も次にセッションを開いたときに必ず拾うため（2026-10-29、ユーザー指定）。
# 集計は約 23 秒かかるので、バックグラウンドで回してセッション開始を待たせない。保存された集計を読むだけなら数十 ms。
set -u

STATE="${AGENT_DOCTOR_STATE_DIR:-$HOME/.local/state/agent-doctor}"
# -I(分離モード。transcript を読む script に、作業ディレクトリの同名モジュールを読ませない)を渡すために python を挟む。
# plugin では、この script の 1 つ上に skills/agent-doctor がある。
ANALYZE="$(cd "$(dirname "$0")/.." && pwd)/skills/agent-doctor/scripts/analyze.py"
COMMAND="${AGENT_DOCTOR_COMMAND:-uv run --no-project python -I \"$ANALYZE\" --days 7}"
mkdir -p "$STATE" || exit 0

latest=$(ls -t "$STATE"/2*.json 2>/dev/null | head -1)

# 最新の集計が無いか 7 日より古ければ起動する。.running が 1 時間以内なら実行中とみなして重ねない
if [[ -z "$latest" || -n "$(find "$latest" -mtime +7 2>/dev/null)" ]]; then
  if [[ -z "$(find "$STATE/.running" -mmin -60 2>/dev/null)" ]]; then
    touch "$STATE/.running"
    nohup bash -c "{ $COMMAND; } >\"$STATE/last-run.log\" 2>&1; rm -f \"$STATE/.running\"" >/dev/null 2>&1 &
  fi
fi

[[ -n "$latest" ]] || exit 0
[[ "$(cat "$STATE/.notified" 2>/dev/null)" == "$latest" ]] && exit 0
echo "$latest" >"$STATE/.notified"

python3 - "$latest" <<'EOF'
import json, sys
path = sys.argv[1]
try:
    report = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(0)
anomalies = report.get("anomalies") or []
if anomalies:
    print(f"agent-doctor の週次集計（{report.get('saved_at', '')[:10]}）で、開発を遅くしている異常が {len(anomalies)} 件見つかった。"
          "最初の返答の最後に、ユーザーへ 1 件 1 行で知らせ、直すかを聞く（直し方は agent-doctor skill の references/diagnosis.md、"
          f"集計の全体は {path}）:")
    for line in anomalies:
        print(f"- {line}")
EOF
