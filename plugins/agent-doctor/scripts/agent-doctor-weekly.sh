#!/bin/bash
# SessionStart: agent-doctor の速度の集計と料金の換算を週 1 回自動で回し、異常と料金の急増を次のセッションで 1 回だけ知らせる。
# launchd ではなく hook にしたのは、PC が止まっていた週も次にセッションを開いたときに必ず拾うため（2026-10-29、ユーザー指定）。
# 集計は約 23 秒かかるので、バックグラウンドで回してセッション開始を待たせない。保存された集計を読むだけなら数十 ms。
set -u

STATE="${AGENT_DOCTOR_STATE_DIR:-$HOME/.local/state/agent-doctor}"
# -I(分離モード。transcript を読む script に、作業ディレクトリの同名モジュールを読ませない)を渡すために python を挟む。
# plugin では、この script の 1 つ上に skills/agent-doctor がある。
ANALYZE="$(cd "$(dirname "$0")/.." && pwd)/skills/agent-doctor/scripts/analyze.py"
API_COST="${AGENT_DOCTOR_API_COST:-$(dirname "$ANALYZE")/api_cost.py}"
COMMAND="${AGENT_DOCTOR_COMMAND:-uv run --no-project python -I \"$ANALYZE\" --days 7 --state-dir \"$STATE\"}"
mkdir -p "$STATE/cost" || exit 0

# 換算の結果を cost/ に保存する。単価表に無いモデルで止まったら、握り潰さず cost-error.txt に残して知らせる。
run_cost() {
  if [[ -n "${AGENT_DOCTOR_COST_COMMAND:-}" ]]; then
    eval "$AGENT_DOCTOR_COST_COMMAND"
    return
  fi
  local out="$STATE/cost/$(date +%Y%m%d-%H%M%S).json"
  uv run --no-project python -I "$API_COST" --days 7 --json >"$out.tmp" 2>"$STATE/cost-stderr.txt"
  if [[ $? -eq 0 ]]; then
    mv "$out.tmp" "$out"
    return
  fi
  rm -f "$out.tmp"
  # 終了コード 2 は python が script を開けないときにも返すので、文言で見分ける
  grep -q '単価表に無い' "$STATE/cost-stderr.txt" && mv "$STATE/cost-stderr.txt" "$STATE/cost-error.txt"
  return 0
}

latest=$(ls -t "$STATE"/2*.json 2>/dev/null | head -1)

# 最新の集計が無いか 7 日より古ければ起動する。.running が 1 時間以内なら実行中とみなして重ねない
if [[ -z "$latest" || -n "$(find "$latest" -mtime +7 2>/dev/null)" ]]; then
  if [[ -z "$(find "$STATE/.running" -mmin -60 2>/dev/null)" ]]; then
    touch "$STATE/.running"
    # 端末を閉じても集計が止まらないよう、HUP を無視してから回す（nohup の代わり。関数を渡せるよう subshell にした）
    ( trap '' HUP; { eval "$COMMAND"; run_cost; } >"$STATE/last-run.log" 2>&1; rm -f "$STATE/.running" ) </dev/null >/dev/null 2>&1 &
  fi
fi

python3 - "$STATE" <<'EOF'
import json, sys
from pathlib import Path

state = Path(sys.argv[1])
# 前回の 1 日あたりがこれ未満の週は、倍率が大きくても知らせない（ほぼ使わなかった週との比較は誤報になる）
MIN_PREVIOUS_PER_DAY = 1.0
RATIO = 2.0


def load(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def latch(marker, value):
    """同じものを 2 回知らせない。新しければ印を付けて True。"""
    path = state / marker
    if path.exists() and path.read_text(encoding="utf-8").strip() == value:
        return False
    path.write_text(value, encoding="utf-8")
    return True


def top(costs):
    return "、".join(f"{k} ${v:,.0f}" for k, v in sorted((costs or {}).items(), key=lambda kv: -kv[1])[:3])


snapshots = sorted(state.glob("2*.json"))
if snapshots and latch(".notified", str(snapshots[-1])):
    report = load(snapshots[-1]) or {}
    path = snapshots[-1]
    anomalies = report.get("anomalies") or []
    if anomalies:
        print(f"agent-doctor の週次集計（{report.get('saved_at', '')[:10]}）で、開発を遅くしている異常が {len(anomalies)} 件見つかった。"
              "最初の返答の最後に、ユーザーへ 1 件 1 行で知らせ、直すかを聞く（直し方は agent-doctor skill の references/diagnosis.md、"
              f"集計の全体は {path}）:")
        for line in anomalies:
            print(f"- {line}")

error = state / "cost-error.txt"
if error.exists():
    print(f"agent-doctor の週次の料金換算が止まった（{error.read_text(encoding='utf-8').strip()}）。単価表が古いので、"
          "最初の返答の最後にユーザーへ 1 行で知らせる（直し方は agent-doctor skill の references/cost.md の「終了コード 2 で止まったとき」）。")
    error.unlink()

costs = sorted((state / "cost").glob("2*.json"))
if len(costs) >= 2 and latch(".cost-notified", str(costs[-1])):
    now, before = load(costs[-1]) or {}, load(costs[-2]) or {}
    if now.get("active_days") and before.get("active_days"):
        per_now = now["total"] / now["active_days"]
        per_before = before["total"] / before["active_days"]
        if per_before >= MIN_PREVIOUS_PER_DAY and per_now >= per_before * RATIO:
            print(f"agent-doctor の週次の料金換算で、稼働日 1 日あたりが前回の {per_now / per_before:.1f} 倍"
                  f"（${per_before:,.2f} → ${per_now:,.2f}）になった。最初の返答の最後に、ユーザーへ 1 行で知らせ、"
                  f"原因を診るかを聞く（読み方は agent-doctor skill の references/cost.md、換算の全体は {costs[-1]}）。")
            print(f"- 上位のエージェント: {top(now.get('by_agent'))}")
            print(f"- 上位の project: {top(now.get('by_project'))}")
EOF
