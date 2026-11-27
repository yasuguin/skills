"""Claude Code の会話ログ(~/.claude/projects/**/*.jsonl)から、時間の使い道と遅さの原因を集計する。

使い方: uv run --no-project python -I analyze.py [--days 7] [--project 部分文字列] [--json]
集計結果は --state-dir(既定 ~/.local/state/agent-doctor)へ保存し、前回の保存と比べた差も出す。
標準ライブラリだけで動く。ログの形式は Claude Code の版で変わりうるので、取れない項目は 0 になる。
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import time
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

BASH_CATEGORIES = [
    (r"vitest|vp test|pnpm (run )?test|jest|playwright|pytest|test:e2e|verify run test", "test"),
    (r"tsc|typecheck|vp check|lint|oxlint|biome|verify run", "lint/type"),
    (r"build", "build"),
    (r"pnpm (i|install|add)\b|bun install|uv sync", "install"),
    (r"^(git|gh) ", "git/gh"),
    (r"\bsleep\b", "sleep"),
]
TRIVIAL = re.compile(r"^(cat|ls|head|tail|grep|rg|sed -n|wc|echo|pwd|find) ")
HOOK_ERROR = re.compile(r"command not found|invalid option|syntax error|Traceback|No such file|Permission denied")
# 本来すぐ終わる操作。中央値が QUICK_LIMIT 秒を超えたら、本体ではなく git hook や、コマンドが呼ぶ script・
# テンプレートが重い疑いが強い（2026-10-29、check_skill_refs.py が 1 ファイルずつ git show して pre-commit が
# 104 秒、pre-push が 76 秒かかっていたのに、分類「git/gh」の平均 12 秒に埋もれて誰も気づかなかった）。
QUICK_COMMANDS = ("git commit", "git push", "git status", "git add", "git pull")
QUICK_LIMIT = 10
# 毎回動く hook の平均がこれを超えたら、ツール呼び出しごとの固定費として指摘する
HOOK_AVG_LIMIT = 2
HOOK_TIMEOUT_SECONDS = 590
# まれにしか起きない長い待ちは平均に埋もれるので、3 回以上の p90 で見る（2026-10-29、stop-reminders.py が
# git status の 15 秒タイムアウトを 2 回待って 30 秒止まっていたのが、平均 3 秒の陰に隠れていた）
HOOK_P90_LIMIT = 10
# 親が終わって launchd（PPID 1）に引き取られたまま CPU を使い続ける開発用プロセス。2026-10-29、ある repo の
# `tsx src/api/server.ts` 2 本がポートも待ち受けずに 7 日間 CPU 100% を使い続け、ログには何も残らず気づけなかった
RUNAWAY_COMMAND = re.compile(r"\b(node|tsx|vite|vitest|bun|deno|python3?|uv|pnpm|playwright|esbuild|next)\b")
RUNAWAY_CPU_MINUTES = 60
STOP_NOISE = ("終了前の確認", "今回の変更だけ", "残すなら", "未コミットは同じ", "触ったセッション")


def ts(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def records(path):
    with open(path, errors="ignore") as stream:
        for line in stream:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def contents(record):
    content = (record.get("message") or {}).get("content")
    return [item for item in content if isinstance(item, dict)] if isinstance(content, list) else []


def text_of(record):
    content = (record.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    return " ".join(item.get("text", "") for item in contents(record) if item.get("type") == "text")


def bash_category(command):
    first = command.strip().split("\n")[0]
    return next((name for pattern, name in BASH_CATEGORIES if re.search(pattern, first)), "other")


def command_head(command):
    # 「cd X; git commit -m …」のような前置きと環境変数の代入を飛ばし、操作を表す先頭の 2 語にする
    first = re.split(r"\s*(?:;|&&|\n)\s*", command.strip())
    for part in first:
        words = [w for w in part.split() if not re.match(r"^[A-Z_][A-Z0-9_]*=", w)]
        if words and words[0] not in ("cd", "export", "set", "time"):
            return " ".join(words[:2])
    return ""


def cpu_minutes(value):
    # macOS の ps は「分:秒.小数」、Linux は「[日-]時:分:秒」
    days, _, clock = value.rpartition("-")
    parts = [float(part) for part in clock.split(":")]
    if len(parts) == 2:
        return parts[0] + parts[1] / 60
    return (float(days or 0) * 24 + parts[0]) * 60 + parts[1] + parts[2] / 60


def runaway_processes():
    source = os.environ.get("AGENT_DOCTOR_PS_FILE")
    try:
        text = Path(source).read_text(encoding="utf-8") if source else subprocess.run(
            ["ps", "-axo", "pid=,ppid=,uid=,time=,etime=,command="], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return []  # sandbox では ps が使えない。週次の SessionStart hook は sandbox の外で動くのでそちらで拾う
    found = []
    for line in text.splitlines():
        fields = line.split(None, 5)
        if len(fields) < 6 or fields[1] != "1" or fields[2] != str(os.getuid()):
            continue
        minutes = cpu_minutes(fields[3])
        if minutes >= RUNAWAY_CPU_MINUTES and RUNAWAY_COMMAND.search(fields[5]):
            found.append(f"親の無いプロセス PID {fields[0]} が CPU 時間 {round(minutes / 60, 1)} 時間を使っている（起動から {fields[4]}）: "
                         f"`{fields[5][:120]}`。ポートを待ち受けていなければ不要なので、`kill {fields[0]}` をユーザーに提案する")
    return found


CI_MIN_RUNS = 5
CI_FAILURE_RATE = 0.25
CI_RED_SECONDS = 24 * 3600


def find_anomalies(commands, hooks):
    found = runaway_processes()
    for head, values in commands.items():
        median = percentile(values, 0.5)
        if head in QUICK_COMMANDS and len(values) >= 3 and median > QUICK_LIMIT:
            found.append(f"本来すぐ終わる `{head}` が中央値 {round(median)} 秒（{len(values)} 回、合計 {round(sum(values) / 3600, 2)}h）。"
                         "git hook（.githooks・.husky・lefthook）や、コマンドが呼ぶ script・テンプレートで遅い検査を測る")
    for name, values in hooks.items():
        if max(values) >= HOOK_TIMEOUT_SECONDS:
            found.append(f"hook `{name}` がタイムアウト（{round(max(values))} 秒）に達した。待ちの原因（ロック・ネットワーク・入力待ち）を調べる")
        elif len(values) >= 3 and percentile(values, 0.9) >= HOOK_P90_LIMIT:
            found.append(f"hook `{name}` が時々長く止まる（p90 {round(percentile(values, 0.9))} 秒、{len(values)} 回）。"
                         "タイムアウト付きの外部コマンド（git status・ネットワーク）の待ちを疑う")
        elif len(values) >= 20 and sum(values) / len(values) > HOOK_AVG_LIMIT:
            found.append(f"hook `{name}` が毎回平均 {round(sum(values) / len(values), 1)} 秒（{len(values)} 回、合計 {round(sum(values) / 3600, 2)}h）。"
                         "1 件ずつ subprocess を起こす処理やネットワーク待ちを疑う")
    return found


def ci_health(slug, runs):
    # 既定ブランチへの push の CI を workflow ごとに見る。赤の上に push が積み重なる状態は放っておくと元に戻るので、
    # 週次で知らせる(ある repo は 30 日で 3 割が失敗、赤が 139 時間続いた回があった。2026-11-06)。
    found = []
    by_workflow = defaultdict(list)
    for run in sorted(runs, key=lambda item: item["createdAt"]):
        if run.get("conclusion") in ("success", "failure"):
            by_workflow[run.get("workflowName", "?")].append(run)
    for workflow, items in by_workflow.items():
        failures = sum(run["conclusion"] == "failure" for run in items)
        if len(items) >= CI_MIN_RUNS and failures / len(items) >= CI_FAILURE_RATE:
            found.append(f"{slug} の CI `{workflow}` が {round(100 * failures / len(items))}% 失敗している（{len(items)} 回中 {failures} 回）。"
                         "手元で気づけない原因（検査範囲の差・不安定なテスト・赤の上への push）を調べる")
        start, longest = None, 0
        for run in items:
            moment = datetime.fromisoformat(run["createdAt"].replace("Z", "+00:00")).timestamp()
            if run["conclusion"] == "failure":
                start = start if start is not None else moment
            elif start is not None:
                longest, start = max(longest, moment - start), None
        if len(items) >= CI_MIN_RUNS and longest >= CI_RED_SECONDS:
            found.append(f"{slug} の CI `{workflow}` の赤が最長 {round(longest / 3600)} 時間続いた。赤の通知が届いていないか、放置されている")
    return found


def recent_repos(projects_dir, days):
    # 最近の会話の cwd から、push 先の owner/repo を集める。
    limit = time.time() - days * 86400
    cwds = set()
    for path in Path(projects_dir).glob("*/*.jsonl"):
        if path.stat().st_mtime < limit:
            continue
        with path.open(encoding="utf-8", errors="ignore") as stream:
            for line in stream:
                match = re.search(r'"cwd":"([^"]+)"', line)
                if match:
                    cwds.add(match.group(1))
                    break
    slugs = set()
    for cwd in cwds:
        done = subprocess.run(["git", "-C", cwd, "remote", "get-url", "origin"], capture_output=True, text=True)
        match = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", done.stdout.strip())
        if done.returncode == 0 and match:
            slugs.add(match.group(1))
    return sorted(slugs)


def ci_anomalies(projects_dir, days):
    since = datetime.fromtimestamp(time.time() - days * 86400).strftime("%Y-%m-%d")
    found = []
    for slug in recent_repos(projects_dir, days):
        try:
            done = subprocess.run(["gh", "run", "list", "-R", slug, "--branch", "main", "--event", "push", "--created", f">={since}",
                                   "--limit", "200", "--json", "workflowName,conclusion,createdAt"],
                                  capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            return found  # gh が無い環境やネットワーク断では知らせない。次の週次で拾う
        if done.returncode == 0:
            found += ci_health(slug, json.loads(done.stdout or "[]"))
    return found


def hook_key(event, command):
    tokens = (command or "?").split()
    return f"{event} {os.path.basename(tokens[-1].strip(chr(34)))}" if tokens else f"{event} ?"


def stop_kinds(text):
    # Stop hook の block 文から指摘の種類だけを取り出す。見出し行は「[ID] 種類: …」か「種類: …」で、
    # 字下げ行は見出しの下の個別項目。stop-reminders 以外の Stop hook は 1 行目を種類とみなす。
    if "終了前の確認" not in text:
        return {text.strip().split("\n")[0][:24]}
    kinds = set()
    for line in text.split("\n"):
        if not line.strip() or line.startswith(" ") or line.startswith(STOP_NOISE):
            continue
        head = re.sub(r"^\[[0-9a-f]+\]\s*", "", line)
        head = re.split(r"[:：]", head, maxsplit=1)[0]
        kinds.add(re.sub(r"（.*?）|\(.*?\)", "", head).strip())
    return kinds


def result_text(item):
    content = item.get("content")
    if isinstance(content, list):
        return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return str(content or "")


def guard_denial(item):
    # 正当な操作がガードに止められた tool_result を (種類, 値) で返す。hook の拒否は理由の先頭、
    # classifier の拒否は規則名で数える。
    if not item.get("is_error"):
        return None
    text = result_text(item)
    if text.startswith("PreToolUse:") and "hook error: " in text:
        reason = text.split("hook error: ", 1)[1].split("\n", 1)[0].strip()
        return "hook", reason[:40]
    match = re.search(r"denied by the Claude Code auto mode classifier\. Reason: \[([^\]]+)\]", text)
    return ("classifier", match.group(1)) if match else None


def percentile(values, ratio):
    ordered = sorted(values)
    return ordered[min(int(len(ordered) * ratio), len(ordered) - 1)] if ordered else 0


def summarize(values):
    return {"count": len(values), "hours": round(sum(values) / 3600, 2),
            "avg_seconds": round(sum(values) / len(values), 1) if values else 0,
            "max_seconds": round(max(values)) if values else 0}


DELIVERY_TYPES = ("worker", "senior-worker")
EDIT_TOOLS = ("Edit", "Write")


def agent_id_of(value):
    return value.removeprefix("agent-")


def read_main_log(path):
    """メインログから、委譲・納品時刻・差し戻し宛先・Edit/Write を集める。"""
    info = {"spawns": {}, "handbacks": {}, "sent_to": set(), "edits": [], "spawn_times": []}
    for record in records(path):
        moment = ts(record["timestamp"]) if record.get("timestamp") else None
        if record.get("type") == "queue-operation" and record.get("operation") == "enqueue":
            text = str(record.get("content", ""))
            for agent in re.findall(r'<agent-message from="([^"]+)"|<task-id>([^<]+)</task-id>', text):
                agent = agent_id_of(agent[0] or agent[1])
                if moment is not None:
                    info["handbacks"][agent] = min(moment, info["handbacks"].get(agent, moment))
            continue
        if record.get("type") != "assistant":
            continue
        for item in contents(record):
            if item.get("type") != "tool_use":
                continue
            tool_input = item.get("input") or {}
            if item.get("name") == "Agent":
                if moment is not None and tool_input.get("subagent_type") in DELIVERY_TYPES:
                    info["spawn_times"].append(moment)
                info["spawns"][item.get("id")] = {"type": tool_input.get("subagent_type"),
                                                  "description": tool_input.get("description")}
            elif item.get("name") == "SendMessage":
                info["sent_to"].add(agent_id_of(str(tool_input.get("to", ""))))
            elif item.get("name") in EDIT_TOOLS and moment is not None and tool_input.get("file_path"):
                info["edits"].append((moment, tool_input["file_path"]))
    return info


TEST_PATTERN = re.compile(BASH_CATEGORIES[0][0])
# `| tail` などで exit code が隠れても、テスト出力の失敗の要約から fail と判定する
TEST_FAILURE = re.compile(r"\b\d+ failed\b|Tests? .*\d+ fail|\bFAILED\b")


def git_added_paths(command):
    # worker は自分の編集ファイルだけを git add するので、Edit を使わない編集の最も確実な代理指標になる
    paths = set()
    for args in re.findall(r"git add\s+([^\n;&|]*)", command):
        for token in args.split():
            token = token.strip("'\"")
            if token and not token.startswith("-") and "$" not in token and token != ".":
                paths.add(token)
    return paths


def same_file(left, right):
    return left == right or left.endswith("/" + right) or right.endswith("/" + left)


def read_sub_run(path):
    """subagent ログ 1 本（run）から納品成績の信号を取る。"""
    last_test_id, test_failed = None, {}
    files, message_ids, moments = set(), set(), []
    for record in records(path):
        if record.get("timestamp"):
            moments.append(ts(record["timestamp"]))
        if record.get("type") == "assistant":
            message_ids.add((record.get("message") or {}).get("id") or id(record))
        for item in contents(record):
            if item.get("type") == "tool_use":
                tool_input = item.get("input") or {}
                command = str(tool_input.get("command", ""))
                if item.get("name") == "Bash":
                    files |= git_added_paths(command)
                    if TEST_PATTERN.search(command):
                        last_test_id = item.get("id")
                elif item.get("name") in EDIT_TOOLS and tool_input.get("file_path"):
                    files.add(tool_input["file_path"])
            elif item.get("type") == "tool_result":
                test_failed[item.get("tool_use_id")] = bool(item.get("is_error")) or bool(TEST_FAILURE.search(result_text(item)))
    last_test = None if last_test_id is None else ("fail" if test_failed.get(last_test_id) else "pass")
    return {"last_test": last_test, "files": files, "messages": len(message_ids),
            "seconds": round(max(moments) - min(moments)) if moments else 0, "ended": max(moments, default=0)}


def delivery(projects_dir, days, project_filter):
    """worker / senior-worker の納品成績を既存ログから推定する。メインを先に読み、subagent を join する 2 パス。"""
    cut = time.time() - days * 86400
    paths = [p for p in Path(projects_dir).glob("**/*.jsonl")
             if os.path.getmtime(p) >= cut and not (project_filter and project_filter not in str(p))]
    mains = {p: read_main_log(p) for p in paths if "/subagents/" not in str(p)}
    runs = []
    for path in paths:
        if "/subagents/" not in str(path):
            continue
        session = path.parent.parent
        main_path = session.with_suffix(".jsonl")
        main = mains.get(main_path) or {"spawns": {}, "handbacks": {}, "sent_to": set(), "edits": [],
                                                      "spawn_times": []}
        try:
            meta = json.loads(path.with_suffix(".meta.json").read_text())
        except (OSError, ValueError):
            meta = {}
        spawn = main["spawns"].get(meta.get("toolUseId")) or {}
        agent_type = spawn.get("type") or meta.get("agentType")
        if agent_type not in DELIVERY_TYPES:
            continue
        agent = agent_id_of(path.stem)
        run = read_sub_run(path)
        handed = main["handbacks"].get(agent)
        sent_back = agent in main["sent_to"]
        # 次の worker 系の起動以降は別タスクの編集とみなし、手直しに数えない
        window_end = min((t for t in main["spawn_times"] if handed is not None and t > handed), default=float("inf"))
        taken_over = handed is not None and any(
            handed <= moment < window_end and any(same_file(name, mine) for mine in run["files"]) for moment, name in main["edits"])
        signals = [name for name, on in (("sent_back", sent_back), ("taken_over", taken_over),
                                         ("test_failed", run["last_test"] == "fail")) if on]
        runs.append({"type": agent_type, "description": meta.get("description") or spawn.get("description") or "",
                     "session": str(main_path), "signals": signals, "files": len(run["files"]),
                     "messages": run["messages"], "seconds": run["seconds"], "last_test": run["last_test"],
                     "accepted_first": not signals, "ended": run["ended"]})
    by_type = {}
    for name in DELIVERY_TYPES:
        mine = [r for r in runs if r["type"] == name]
        tested = [r for r in mine if r["last_test"] is not None]
        by_type[name] = {"runs": len(mine), "tested_runs": len(tested),
                         "test_pass_rate": round(sum(r["last_test"] == "pass" for r in tested) / len(tested), 2) if tested else None,
                         "sent_back": sum("sent_back" in r["signals"] for r in mine),
                         "taken_over": sum("taken_over" in r["signals"] for r in mine),
                         "accepted_first": sum(r["accepted_first"] for r in mine)}

    def candidates(selected):
        newest = sorted(selected, key=lambda r: -r["ended"])[:20]
        return [{key: r[key] for key in ("type", "description", "session", "signals", "files", "messages")} for r in newest]

    return {"by_type": by_type,
            "underpowered_candidates": candidates([r for r in runs if r["type"] == "worker" and r["signals"]]),
            "overspec_candidates": candidates([r for r in runs if r["type"] == "senior-worker" and r["accepted_first"]
                                               and r["files"] <= 2 and r["messages"] <= 15])}


def analyze(projects_dir, days, project_filter):
    cut = time.time() - days * 86400
    turns, model, model_first, model_out = [], defaultdict(list), defaultdict(list), defaultdict(int)
    tools, bash, slow, trivial = defaultdict(list), defaultdict(list), [], []
    commands = defaultdict(list)
    hooks, hook_errors = defaultdict(list), Counter()
    stop = {"total": 0, "kinds": Counter(), "acks": 0, "ack_reasons": Counter()}
    guard = {"hook": Counter(), "classifier": Counter(), "unsandboxed_retries": 0}
    skills,delegations, overrides, actual_models = Counter(), Counter(), Counter(), Counter()
    questions, question_wait, per_session_questions = 0, 0.0, []
    per_session_tests, per_session_verify = [], []
    context, baseline = [], []
    prompt_writing, notification_turns = [], []
    check_failures = 0
    sub_runs, sub_seconds, sub_out = Counter(), defaultdict(float), Counter()
    sub_models, sub_memory, sub_mcp = defaultdict(Counter), Counter(), Counter()
    for path in Path(projects_dir).glob("**/*.jsonl"):
        if os.path.getmtime(path) < cut or (project_filter and project_filter not in str(path)):
            continue
        sub = "/subagents/" in str(path)
        tag = "sub" if sub else "main"
        agent_type = None
        if sub:
            meta = path.with_suffix(".meta.json")
            info = json.loads(meta.read_text()) if meta.exists() else {}
            agent_type = info.get("agentType", "?")
        first_moment = last_moment = None
        previous, messages, pending = None, {}, {}
        session_questions = session_tests = session_verify = 0
        turn_start, turn_kind, last = None, None, None
        for record in records(path):
            stamp = record.get("timestamp")
            if not stamp:
                continue
            moment = ts(stamp)
            if moment < cut:
                continue
            if first_moment is None:
                first_moment = moment
            last_moment = moment
            kind = record.get("type")
            if kind == "user":
                items = contents(record)
                is_result = any(item.get("type") == "tool_result" for item in items)
                if not sub and not is_result and not record.get("isMeta") and text_of(record).strip():
                    if turn_kind == "notification" and turn_start is not None:
                        notification_turns.append((last or moment) - turn_start)
                    turn_start = moment
                    turn_kind = "notification" if "<task-notification" in text_of(record) else "user"
                for item in items:
                    denial = guard_denial(item) if item.get("type") == "tool_result" else None
                    if denial:
                        guard[denial[0]][denial[1]] += 1
                    if item.get("type") != "tool_result" or item.get("tool_use_id") not in pending:
                        continue
                    started, name, command = pending.pop(item["tool_use_id"])
                    took = moment - started
                    tools[f"{tag}:{name}"].append(took)
                    if name == "AskUserQuestion":
                        question_wait += took
                    if name == "Bash":
                        bash[bash_category(command)].append(took)
                        commands[command_head(command)].append(took)
                        # メインで起きた検査の失敗。既定はメインが直すので、quick-fixer への委譲と並べて委譲の偏りを見る
                        if not sub and item.get("is_error") and bash_category(command) in ("lint/type", "test"):
                            check_failures += 1
                        if took > 60:
                            slow.append((round(took), tag, command.strip().split("\n")[0][:120]))
                        if TRIVIAL.match(command) and not re.search(r"[|&;\n]", command):
                            trivial.append(took)
                previous = moment
            elif kind == "assistant":
                message = record.get("message") or {}
                key = message.get("id")
                if key not in messages:
                    messages[key] = {"start": previous, "first": moment, "model": message.get("model")}
                messages[key]["last"] = moment
                messages[key]["usage"] = message.get("usage") or {}
                for item in contents(record):
                    if item.get("type") != "tool_use":
                        continue
                    name, payload = item.get("name"), item.get("input") or {}
                    command = payload.get("command", "") if name == "Bash" else ""
                    pending[item.get("id")] = (moment, name, command)
                    if name == "Skill":
                        skills[payload.get("skill")] += 1
                    if sub and str(name).startswith("mcp__"):
                        sub_mcp[agent_type] += 1
                    if name == "AskUserQuestion" and not sub:
                        questions += 1
                        session_questions += 1
                    if name == "Agent":
                        agent = payload.get("subagent_type") or "general-purpose"
                        delegations[agent] += 1
                        if agent in ("worker", "senior-worker"):
                            if payload.get("model"):
                                overrides[payload["model"]] += 1
                            if messages[key]["start"] is not None:
                                prompt_writing.append(moment - messages[key]["start"])
                    if name == "Bash":
                        if payload.get("dangerouslyDisableSandbox") is True:
                            guard["unsandboxed_retries"] += 1
                        if re.search(r"verify run", command):
                            session_verify += 1
                        elif bash_category(command) == "test":
                            session_tests += 1
                        if "stop-reminders.py" in command and "--ack" in command:
                            stop["acks"] += 1
                            reason = re.search(r"--reason '([^']*)'", command)
                            if reason:
                                stop["ack_reasons"][reason.group(1)[:60]] += 1
            elif kind == "attachment":
                attachment = record.get("attachment") or {}
                if attachment.get("durationMs") is not None and str(attachment.get("type", "")).startswith("hook_"):
                    hook = hook_key(attachment.get("hookEvent", "?"), attachment.get("command"))
                    hooks[hook].append(attachment["durationMs"] / 1000)
                    if HOOK_ERROR.search(str(attachment.get("stderr", ""))):
                        hook_errors[hook] += 1
                if attachment.get("type") == "hook_blocking_error" and not sub:
                    blocking = attachment.get("blockingError")
                    text = blocking.get("blockingError", "") if isinstance(blocking, dict) else str(blocking or "")
                    stop["total"] += 1
                    stop["kinds"].update(stop_kinds(text))
            elif kind == "system":
                if record.get("subtype") == "turn_duration" and not sub:
                    turns.append(record.get("durationMs", 0) / 1000)
                    if turn_kind == "notification" and turn_start is not None:
                        notification_turns.append(moment - turn_start)
                    turn_start = None
                if record.get("subtype") == "stop_hook_summary":
                    for info in record.get("hookInfos") or []:
                        if "durationMs" in info:
                            hooks[hook_key("Stop", info.get("command"))].append(info["durationMs"] / 1000)
            last = moment
        first_context = None
        for value in messages.values():
            if value["start"] is None:
                continue
            took = value["last"] - value["start"]
            if took < 0 or took > 1800:
                continue
            label = f"{tag}:{value['model']}"
            model[label].append(took)
            model_first[label].append(value["first"] - value["start"])
            usage = value["usage"]
            model_out[label] += usage.get("output_tokens", 0)
            size = sum(usage.get(name, 0) for name in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
            if not sub:
                context.append(size)
                first_context = first_context if first_context is not None else size
        if sub and messages:
            first_model = next((value["model"] for value in messages.values() if value["model"]), "?")
            actual_models[f"{agent_type}:{first_model}"] += 1
            sub_models[agent_type][first_model] += 1
        if sub and first_moment is not None and last_moment is not None:
            sub_runs[agent_type] += 1
            sub_seconds[agent_type] += last_moment - first_moment
            sub_out[agent_type] += sum(value["usage"].get("output_tokens", 0) for value in messages.values())
        if not sub:
            if first_context:
                baseline.append(first_context)
            per_session_questions.append(session_questions)
            per_session_tests.append(session_tests)
            per_session_verify.append(session_verify)
    return {
        "days": days,
        "turns": {"count": len(turns), "hours": round(sum(turns) / 3600, 2),
                  "avg_seconds": round(sum(turns) / len(turns)) if turns else 0},
        "model_calls": {label: {"calls": len(values), "hours": round(sum(values) / 3600, 2),
                                "avg_seconds": round(sum(values) / len(values), 1),
                                "first_chunk_seconds": round(statistics.mean(model_first[label]), 1),
                                "output_tokens_per_second": round(model_out[label] / max(sum(values), 1), 1)}
                        for label, values in sorted(model.items(), key=lambda pair: -sum(pair[1]))},
        "context_tokens": {"p50": percentile(context, 0.5), "p90": percentile(context, 0.9),
                           "max": max(context, default=0), "session_start_p50": percentile(baseline, 0.5)},
        "tools": {name: summarize(values) for name, values in sorted(tools.items(), key=lambda pair: -sum(pair[1]))[:15]},
        "bash_categories": {name: summarize(values) for name, values in sorted(bash.items(), key=lambda pair: -sum(pair[1]))},
        "slowest_bash": sorted(slow, reverse=True)[:10],
        "commands": {name: summarize(values) for name, values in sorted(commands.items(), key=lambda pair: -sum(pair[1]))[:20]},
        "anomalies": find_anomalies(commands, hooks) + ci_anomalies(projects_dir, days),
        "trivial_bash_seconds": {"count": len(trivial), "p50": round(percentile(trivial, 0.5), 1),
                                 "p90": round(percentile(trivial, 0.9), 1)},
        "hooks": {name: {**summarize(values), "errors": hook_errors[name]}
                  for name, values in sorted(hooks.items(), key=lambda pair: -sum(pair[1]))[:15]},
        "stop_blocks": {"total": stop["total"], "kinds": dict(stop["kinds"].most_common()),
                        "acks": stop["acks"], "ack_reasons": dict(stop["ack_reasons"].most_common(10))},
        "guard_denials": {"hook": {"total": sum(guard["hook"].values()), "reasons": dict(guard["hook"].most_common(10))},
                          "classifier": {"total": sum(guard["classifier"].values()),
                                         "rules": dict(guard["classifier"].most_common())},
                          "unsandboxed_retries": guard["unsandboxed_retries"]},
        "skills": dict(skills.most_common(20)),
        "delegation": {"by_type": dict(delegations.most_common()), "worker_model_overrides": dict(overrides),
                       "actual_models": dict(actual_models.most_common()),
                       "prompt_writing": summarize(prompt_writing), "notification_turns": summarize(notification_turns),
                       "check_failures": check_failures},
        "subagents": {label: {"runs": runs, "hours": round(sub_seconds[label] / 3600, 2),
                              "avg_seconds": round(sub_seconds[label] / runs),
                              "output_tokens": sub_out[label], "models": dict(sub_models[label]),
                              "memory_calls": sub_memory[label], "mcp_calls": sub_mcp[label]}
                      for label, runs in sorted(sub_runs.items(), key=lambda pair: -sub_seconds[pair[0]])},
        "delivery": delivery(projects_dir, days, project_filter),
        "questions": {"count": questions, "wait_hours": round(question_wait / 3600, 2),
                      "per_session_max": max(per_session_questions, default=0)},
        "verification": {"test_runs_per_session_max": max(per_session_tests, default=0),
                         "test_runs_per_session_p90": percentile(per_session_tests, 0.9),
                         "verify_runs_per_session_max": max(per_session_verify, default=0)},
    }


# 前回比に出す指標。改善の効果を確かめたい「往復の回数」と「時間」を選ぶ。
HEADLINE = [
    ("ターン時間の合計(h)", lambda r: r["turns"]["hours"]),
    ("ターン数", lambda r: r["turns"]["count"]),
    ("main のモデル応答(h)", lambda r: sum(v["hours"] for k, v in r["model_calls"].items() if k.startswith("main:"))),
    ("コンテキスト p50", lambda r: r["context_tokens"]["p50"]),
    ("テスト実行(h)", lambda r: r["bash_categories"].get("test", {}).get("hours", 0)),
    ("Stop の block 回数", lambda r: r["stop_blocks"]["total"]),
    ("ack 回数", lambda r: r["stop_blocks"]["acks"]),
    ("hook の拒否", lambda r: r.get("guard_denials", {}).get("hook", {}).get("total", 0)),
    ("classifier の拒否", lambda r: r.get("guard_denials", {}).get("classifier", {}).get("total", 0)),
    ("sandbox 外の再実行", lambda r: r.get("guard_denials", {}).get("unsandboxed_retries", 0)),
    ("質問の回数", lambda r: r["questions"]["count"]),
    ("worker への委譲", lambda r: r["delegation"]["by_type"].get("worker", 0)),
    ("senior-worker への委譲", lambda r: r["delegation"]["by_type"].get("senior-worker", 0)),
    ("検査の失敗（main）", lambda r: r["delegation"].get("check_failures", 0)),
    ("quick-fixer への委譲", lambda r: r["delegation"]["by_type"].get("quick-fixer", 0)),
    ("worker のモデル上書き", lambda r: sum(r["delegation"]["worker_model_overrides"].values())),
    ("worker のテスト通過率", lambda r: "-" if r.get("delivery", {}).get("by_type", {}).get("worker", {}).get("test_pass_rate") is None
     else r["delivery"]["by_type"]["worker"]["test_pass_rate"]),
    ("hook のエラー", lambda r: sum(v["errors"] for v in r["hooks"].values())),
    ("1 セッションの verify 最大", lambda r: r["verification"]["verify_runs_per_session_max"]),
]


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(str(cell) for cell in row) + " |" for row in rows]
    return "\n".join(lines)


def render(report, previous):
    out = [f"# agent-doctor 集計（直近 {report['days']} 日）", ""]
    t = report["turns"]
    out += [f"メインのターン {t['count']} 回、合計 {t['hours']}h、平均 {t['avg_seconds']} 秒", ""]
    out += ["## 自動で見つけた異常", ""] + ([f"- {line}" for line in report["anomalies"]] or ["- なし"]) + [""]
    if previous:
        out += [f"## 前回比（{previous['saved_at']}）", ""]
        out += [table(["指標", "前回", "今回"], [(name, get(previous), get(report)) for name, get in HEADLINE]), ""]
    out += ["## モデルの応答", "", table(["モデル", "回数", "合計h", "平均秒", "最初の出力まで秒", "出力tok/秒"], [
        (k, v["calls"], v["hours"], v["avg_seconds"], v["first_chunk_seconds"], v["output_tokens_per_second"])
        for k, v in report["model_calls"].items()]), ""]
    c = report["context_tokens"]
    out += [f"コンテキスト（main の 1 回あたり入力）: p50 {c['p50']} / p90 {c['p90']} / 最大 {c['max']}、"
            f"セッション開始時 p50 {c['session_start_p50']}", ""]
    out += ["## ツール", "", table(["ツール", "回数", "合計h", "平均秒", "最長秒"], [
        (k, v["count"], v["hours"], v["avg_seconds"], v["max_seconds"]) for k, v in report["tools"].items()]), ""]
    out += ["## Bash の分類", "", table(["分類", "回数", "合計h", "平均秒", "最長秒"], [
        (k, v["count"], v["hours"], v["avg_seconds"], v["max_seconds"]) for k, v in report["bash_categories"].items()]), ""]
    out += ["コマンドの頭ごと（合計の多い順、上位 20）:", "", table(["コマンド", "回数", "合計h", "平均秒", "最長秒"], [
        (f"`{k}`", v["count"], v["hours"], v["avg_seconds"], v["max_seconds"]) for k, v in report["commands"].items()]), ""]
    tb = report["trivial_bash_seconds"]
    out += [f"単純なコマンド（cat / ls など）{tb['count']} 回: p50 {tb['p50']} 秒 / p90 {tb['p90']} 秒（hook 等の固定オーバーヘッドの目安）", ""]
    if report["slowest_bash"]:
        out += ["遅い Bash（60 秒超、上位 10）:", ""] + [f"- {s} 秒 [{tag}] `{cmd}`" for s, tag, cmd in report["slowest_bash"]] + [""]
    out += ["## hook", "", table(["hook", "回数", "合計h", "平均秒", "最長秒", "エラー"], [
        (k, v["count"], v["hours"], v["avg_seconds"], v["max_seconds"], v["errors"]) for k, v in report["hooks"].items()]), ""]
    s = report["stop_blocks"]
    out += ["## Stop hook の block", "", f"合計 {s['total']} 回、ack {s['acks']} 回", ""]
    out += [table(["種類", "回数"], s["kinds"].items()), "", "ack の理由（上位）:", ""]
    out += [f"- {n} 回: {reason}" for reason, n in s["ack_reasons"].items()] + [""]
    g = report["guard_denials"]
    out += ["## ガードに止められた回数", "", f"hook の拒否 {g['hook']['total']} 回、classifier の拒否 {g['classifier']['total']} 回、"
            f"sandbox 外の再実行 {g['unsandboxed_retries']} 回", ""]
    out += [table(["hook の理由（先頭40字）", "回数"], g["hook"]["reasons"].items()), ""]
    out += [table(["classifier の規則", "回数"], g["classifier"]["rules"].items()), ""]
    d = report["delegation"]
    out += ["## 委譲", "", f"Agent の型: {d['by_type']}", f"worker のモデル上書き: {d['worker_model_overrides']}",
            f"subagent の実モデル: {d['actual_models']}",
            f"worker への指示を書く時間: {d['prompt_writing']['hours']}h（平均 {d['prompt_writing']['avg_seconds']} 秒）",
            f"納品通知で始まるターン: {d['notification_turns']['count']} 回、{d['notification_turns']['hours']}h"
            f"（平均 {d['notification_turns']['avg_seconds']} 秒）", ""]
    before = (previous or {}).get("subagents", {})
    extra = ["前回の回数", "前回の合計h"] if previous else []
    out += ["## サブエージェントの型別", "", table(
        ["型", "回数", "合計h", "平均秒", "出力tok", "実モデル", "記憶", "MCP", *extra],
        [(k, v["runs"], v["hours"], v["avg_seconds"], v["output_tokens"], v["models"], v["memory_calls"],
          v["mcp_calls"], *([before.get(k, {}).get("runs", 0), before.get(k, {}).get("hours", 0)] if previous else []))
         for k, v in sorted(report["subagents"].items(), key=lambda pair: -pair[1]["hours"])]), ""]
    dv = report["delivery"]
    out += ["## 委譲の成績", "", table(
        ["型", "回数", "テストした回数", "通過率", "差し戻し", "手直し", "一発受理"],
        [(k, v["runs"], v["tested_runs"], "-" if v["test_pass_rate"] is None else v["test_pass_rate"],
          v["sent_back"], v["taken_over"], v["accepted_first"]) for k, v in dv["by_type"].items()]), ""]
    for title, key in (("worker の力不足の候補", "underpowered_candidates"),
                       ("senior-worker のオーバースペックの候補", "overspec_candidates")):
        out += [f"{title}（新しい順、最大 20）:", ""]
        out += [f"- {c['description']} [{', '.join(c['signals']) or '一発受理'}] 編集 {c['files']} ファイル、{c['messages']} 発言"
                for c in dv[key]] + [""]
    q, v = report["questions"], report["verification"]
    out += ["## 質問・検証・skill", "", f"質問 {q['count']} 回、回答待ち {q['wait_hours']}h、1 セッション最大 {q['per_session_max']} 問",
            f"テスト実行/セッション: 最大 {v['test_runs_per_session_max']}、p90 {v['test_runs_per_session_p90']}、"
            f"verify run/セッション最大 {v['verify_runs_per_session_max']}", f"skill の呼び出し: {report['skills']}"]
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=float, default=7)
    parser.add_argument("--project", help="プロジェクトのディレクトリ名に含まれる文字列で絞る")
    parser.add_argument("--projects-dir", default=str(Path.home() / ".claude/projects"))
    parser.add_argument("--state-dir", default=str(Path.home() / ".local/state/agent-doctor"))
    parser.add_argument("--json", action="store_true", help="集計を JSON で出す")
    args = parser.parse_args()
    report = analyze(args.projects_dir, args.days, args.project)
    state = Path(args.state_dir)
    state.mkdir(parents=True, exist_ok=True)
    saved = sorted(state.glob("*.json"))
    previous = json.loads(saved[-1].read_text()) if saved else None
    now = datetime.now()
    report["saved_at"] = now.strftime("%Y-%m-%d %H:%M")
    (state / f"{now.strftime('%Y%m%d-%H%M%S-%f')}.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))
    print(json.dumps(report, ensure_ascii=False, indent=1) if args.json else render(report, previous))


if __name__ == "__main__":
    main()
