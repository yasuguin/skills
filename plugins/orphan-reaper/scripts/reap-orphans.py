#!/usr/bin/env python3
"""終わった Claude Code セッションが置き去りにした孤児プロセスを片付ける。

2026-10-29、テストランナーの強制終了で孤児になった dev server 2 本が、ポートも待ち受けずに 7 日間 CPU 100% を
使い続けた。テストの書き方を全 repo で揃えるのは強制しきれないので、ユーザーレベルで後から確実に拾う。

止めるのは次のすべてを満たすものだけ（ユーザー決定）:
- PPID 1（親が終わって launchd に引き取られた）で自分の uid
- Claude Code: 環境変数 CLAUDE_PID を持ち（Bash から起動された子孫。人がターミナルで起動したものには無い）、
  そのセッションがもう居ない（pid の再利用は、セッションの方が後から起動していれば別物とみなす）
- Codex: 環境変数 CODEX_THREAD_ID を持ち、その会話の記録（~/.codex/sessions/**/rollout-*-<thread>.jsonl）が
  猶予の間更新されていない。Codex は子に PID を渡さず、会話は常駐の app-server の中にあってプロセスの生死で見られないため
- pi: 環境変数 PI_SESSION_FILE（会話の記録）を持ち、そのファイルが猶予の間更新されていない
- 起動から猶予（既定 15 分）がたっている（セッションの開き直しの間に巻き込まない）
- TCP ポートを待ち受けていない（使っているかもしれない dev server は止めずに知らせるだけ）

launchd（15 分ごと）と SessionStart から呼ぶ。1 回 ps 1 回と候補の環境変数の読み取りだけで、0.1〜0.3 秒。
環境変数は macOS の KERN_PROCARGS2 で読む（`ps -E` は他プロセスの環境変数を出さない。Apple 署名のバイナリは
環境変数が読めないが、対象の node などは読める）。
"""

from argparse import ArgumentParser
import ctypes
from datetime import datetime
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

CTL_KERN, KERN_PROCARGS2 = 1, 49


def environment(pid):
    libc = ctypes.CDLL(None)
    mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
    size = ctypes.c_size_t(1 << 18)
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        return {}
    pairs = {}
    for part in buffer.raw[4 : size.value].split(b"\0"):
        name, sep, value = part.partition(b"=")
        if sep and name.isascii() and name.replace(b"_", b"").isalnum():
            pairs[name.decode()] = value.decode(errors="replace")
    return pairs


def elapsed_seconds(value):
    # ps の etime は「[[日-]時:]分:秒」
    days, _, clock = value.rpartition("-")
    parts = [int(part) for part in clock.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return ((int(days or 0) * 24 + parts[0]) * 60 + parts[1]) * 60 + parts[2]


def process_table():
    output = subprocess.run(["ps", "-axo", "pid=,ppid=,uid=,etime=,command="],
                            capture_output=True, text=True, check=True).stdout
    table = {}
    for line in output.splitlines():
        fields = line.split(None, 4)
        if len(fields) == 5:
            table[int(fields[0])] = (int(fields[1]), int(fields[2]), elapsed_seconds(fields[3]), fields[4])
    return table


def listening(pid):
    result = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN"],
                            capture_output=True, text=True)
    return bool(result.stdout.strip())


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop(pid):
    os.kill(pid, signal.SIGTERM)
    deadline = time.time() + 5
    while alive(pid) and time.time() < deadline:
        time.sleep(0.2)
    if alive(pid):
        # 今回の 2 本は終了処理の途中で空回りし、SIGTERM では終わらなかった
        os.kill(pid, signal.SIGKILL)


def file_idle(path, idle_seconds):
    try:
        return time.time() - Path(path).stat().st_mtime >= idle_seconds
    except OSError:
        return True  # 記録が消えたなら会話も終わっている


def codex_thread_idle(codex_home, thread, idle_seconds):
    logs = list((codex_home / "sessions").glob(f"**/rollout-*-{thread}.jsonl")) if thread else []
    if not logs:
        return bool(thread)  # 記録が見つからない（消えた・別の CODEX_HOME）なら終わったとみなす
    return time.time() - max(log.stat().st_mtime for log in logs) >= idle_seconds


def main():
    parser = ArgumentParser()
    parser.add_argument("--state-dir", default=str(Path.home() / ".local/state/agent-reaper"))
    parser.add_argument("--min-age-minutes", type=float, default=15)
    parser.add_argument("--dry-run", action="store_true")
    # 会話の記録がこの間更新されていなければ、その会話は終わったとみなす（PID を渡さない Codex 用）
    parser.add_argument("--idle-minutes", type=float, default=15)
    parser.add_argument("--codex-home", default=os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    args = parser.parse_args()

    me = os.getuid()
    table = process_table()
    stopped, serving = [], []
    for pid, (ppid, uid, age, command) in table.items():
        if ppid != 1 or uid != me or age < args.min_age_minutes * 60:
            continue
        env = environment(pid)
        session = env.get("CLAUDE_PID", "")
        if session.isdigit():
            owner = table.get(int(session))
            if owner is not None and owner[2] >= age:
                continue  # 起動したセッションがまだ生きている
            agent = "Claude Code"
        elif env.get("CODEX_THREAD_ID"):
            if not codex_thread_idle(Path(args.codex_home), env["CODEX_THREAD_ID"], args.idle_minutes * 60):
                continue
            agent = "Codex"
        elif env.get("PI_SESSION_FILE"):
            if not file_idle(env["PI_SESSION_FILE"], args.idle_minutes * 60):
                continue
            agent = "pi"
        else:
            continue
        if listening(pid):
            serving.append((pid, command, agent))
            continue
        if not args.dry_run:
            try:
                stop(pid)
            except ProcessLookupError:
                continue
        stopped.append((pid, command, agent))

    if stopped and not args.dry_run:
        state = Path(args.state_dir)
        state.mkdir(parents=True, exist_ok=True)
        with (state / "reaped.log").open("a", encoding="utf-8") as log:
            for pid, command, agent in stopped:
                log.write(f"{datetime.now().isoformat(timespec='seconds')}\t{agent}\t{pid}\t{command[:300]}\n")

    verb = "止める対象" if args.dry_run else "止めた"
    for pid, command, agent in stopped:
        print(f"{verb}: PID {pid} `{command[:120]}`（終わった {agent} セッションの置き去り、ポート無し）")
    for pid, command, agent in serving:
        print(f"終わったセッションの置き去りだが、ポートを待ち受けているので止めていない: PID {pid} `{command[:120]}`。"
              f"使っていなければ `kill {pid}` をユーザーに提案する")


if __name__ == "__main__":
    sys.exit(main())
