"""ツール呼び出し 1 回ごとに待つ hook を実際に走らせて測る（agent-doctor の「実測」の工程）。

同じイベントの hook は並列に動くので、1 回の待ちはそのイベントで一番遅い同期 hook で決まる。
2026-10-29、Bash の固定費（単純なコマンドの p50 2.3 秒）は 13 本の hook のうち stop-reminders.py の 3 秒台が
決めていて、残りは 0.2〜0.8 秒だった。ログの集計（analyze.py）では hook ごとの時間が出ない場面があるので、
読むだけのコマンドの入力で 1 本ずつ測る。async の hook は待たないので測らない。

ロードアベレージも出す。並列セッションのテストでコア数の数倍になると、git 1 回が 0.6 秒から 7 秒に膨らみ、
時間の比較が揺れで逆転する。
"""

from argparse import ArgumentParser
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import time

TIMEOUT = 60


def matching_hooks(settings, event, tool):
    found = []
    for group in settings.get("hooks", {}).get(event, []):
        matcher = group.get("matcher") or "*"
        if event in ("PreToolUse", "PostToolUse") and matcher != "*" and not re.fullmatch(matcher, tool):
            continue
        found += [hook for hook in group.get("hooks", []) if hook.get("type") == "command"]
    return found


def timed(command, payload, env):
    start = time.monotonic()
    try:
        subprocess.run(["sh", "-c", command], input=payload, capture_output=True, text=True, env=env, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return float(TIMEOUT)
    return time.monotonic() - start


def main():
    parser = ArgumentParser()
    parser.add_argument("--settings", default=str(Path.home() / ".claude/settings.json"))
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--tool", default="Bash")
    parser.add_argument("--command", default="cat README.md", help="Bash のときに渡すコマンド（既定は読むだけのもの）")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    settings = json.loads(Path(args.settings).read_text(encoding="utf-8"))
    # 状態を書く hook（stop-reminders.py）が本物の記録を汚さないよう、状態の置き場を一時ディレクトリへ向ける
    state = tempfile.mkdtemp(prefix="measure-hooks-")
    env = {**os.environ, "STOP_REMINDERS_STATE_DIR": state}
    tool_input = {"command": args.command} if args.tool == "Bash" else {"file_path": str(Path(args.cwd) / "README.md")}

    events, async_hooks = {}, []
    for event in ("PreToolUse", "PostToolUse", "Stop"):
        payload = json.dumps({"session_id": "measure-hooks", "cwd": args.cwd, "hook_event_name": event,
                              "tool_name": args.tool, "tool_use_id": "measure", "tool_input": tool_input,
                              "stop_hook_active": False})
        rows = []
        for hook in matching_hooks(settings, event, args.tool):
            if hook.get("async"):
                async_hooks.append(hook["command"])
                continue
            seconds = statistics.median(timed(hook["command"], payload, env) for _ in range(args.repeat))
            rows.append({"command": hook["command"], "seconds": round(seconds, 2)})
        if rows:
            rows.sort(key=lambda row: -row["seconds"])
            events[event] = {"wait_seconds": rows[0]["seconds"], "slowest": rows[0]["command"], "hooks": rows}

    report = {"load_average": round(os.getloadavg()[0], 1), "cpu_count": os.cpu_count() or 1,
              "events": events, "async_hooks": sorted(set(async_hooks))}
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=1))
        return
    load, cpus = report["load_average"], report["cpu_count"]
    note = "（コア数の 2 倍超。時間が膨らんでいるので、比べるときは子プロセスの数で見る）" if load > cpus * 2 else ""
    print(f"ロードアベレージ {load}（{cpus} コア）{note}")
    print()
    for event, data in events.items():
        print(f"## {event}: 1 回の待ち {data['wait_seconds']} 秒（一番遅い hook）")
        for row in data["hooks"]:
            print(f"- {row['seconds']} 秒 `{row['command']}`")
        print()
    if report["async_hooks"]:
        print("待たない（async）hook: " + "、".join(f"`{command}`" for command in report["async_hooks"]))


if __name__ == "__main__":
    main()
