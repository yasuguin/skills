#!/usr/bin/env python3
"""ブランチ作成の実績をセッションに記録し、後片付けの許可を判定する。"""

import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path


def git(repo, *args):
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"}, timeout=5)
    return result.stdout.strip() if result.returncode == 0 else ""


def literal(value):
    return bool(value) and not any(c in value for c in "$`*?[]{}\n")


def directory(value, cwd):
    if not literal(value):
        return None
    path = Path(value).expanduser()
    return path.resolve() if path.is_absolute() else (cwd / path).resolve()


HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
SHELL_READER = re.compile(r"(^|[\s;&|(])(ba|z|da)?sh(\s[^;&|]*)?<<")


def without_heredoc_bodies(command):
    """commit メッセージなどの heredoc 本文をコマンドとして読まない。シェルが受ける本文は実行されるので残す。"""
    lines, kept, end = command.split("\n"), [], None
    for line in lines:
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        kept.append(line)
        match = HEREDOC.search(line)
        if match and not SHELL_READER.search(line):
            end = match.group(2)
    return "\n".join(kept)


def commands(command, cwd):
    command = without_heredoc_bodies(command)
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    segment = []
    for token in [*lexer, ";"]:
        if token and all(c in ";&|\n" for c in token):
            if segment:
                while segment and segment[0] in {"do", "then", "else", "command"}:
                    segment = segment[1:]
                if not segment:
                    continue
                if segment[0] == "cd" and len(segment) == 2:
                    cwd = directory(segment[1], cwd) if cwd else None
                else:
                    yield cwd, segment
            segment = []
        else:
            segment.append(token)


def git_command(cwd, argv):
    if not argv or Path(argv[0]).name != "git":
        return None, []
    args = argv[1:]
    while args and args[0].startswith("-"):
        option = args[0]
        if option == "-C" and len(args) > 1:
            cwd = directory(args[1], cwd) if cwd else None
            args = args[2:]
        elif option in {"--no-pager", "--no-optional-locks"}:
            args = args[1:]
        else:
            # git-dir/config の変更は解釈せず、削除なら判定不能として拒む。
            cwd = None
            args = args[2:] if option in {"-c", "--git-dir", "--work-tree"} else args[1:]
    return cwd, args


def branch_operation(args):
    if not args:
        return None, []
    if args[0] == "branch":
        flags = [arg for arg in args[1:] if arg.startswith("-") and arg != "--"]
        names = [arg for arg in args[1:] if not arg.startswith("-")]
        if any(arg == "--delete" or (arg.startswith("-") and not arg.startswith("--")
                                     and any(c in arg[1:] for c in "dD")) for arg in flags):
            return "delete", names
        if not flags and names:
            return "create", names[:1]
    flag = {"switch": "-c", "checkout": "-b", "worktree": "-b"}.get(args[0])
    if flag and flag in args:
        index = args.index(flag) + 1
        if index < len(args):
            return "create", [args[index]]
    return None, []


def common_dir(repo):
    value = git(repo, "rev-parse", "--git-common-dir")
    return directory(value, repo) if value else None


def branch_identity(repo, name):
    if not literal(name) or name.startswith("-"):
        return None
    common = common_dir(repo)
    if not common or not git(repo, "rev-parse", "--verify", "refs/heads/" + name):
        return None
    log = common / "logs" / "refs" / "heads" / name
    if not log.is_file():
        return None
    # 追記されても変わらない作成記録と inode を使い、同名の再作成には許可を継承しない。
    with log.open("rb") as stream:
        first = stream.readline()
    return [str(common), name, log.stat().st_ino, first.decode(errors="replace")]


def key(value):
    return hashlib.sha256(value.encode()).hexdigest()


def state_dir(payload):
    session = payload.get("session_id")
    if not session:
        return None
    root = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    return root / "agent-cleanup" / key(session)


def read_state(path):
    return json.loads(path.read_text()) if path and path.is_file() else None


def write_state(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value))
    temporary.replace(path)


def owned_path(state, repo, name):
    common = common_dir(repo)
    return state / ("branch-" + key(str(common) + "\0" + name) + ".json") if state and common else None


def branch_allowed(state, repo, name):
    if not literal(name) or name.startswith("-"):
        return False
    identity = branch_identity(repo, name)
    if identity and read_state(owned_path(state, repo, name)) == identity:
        return True
    sha = git(repo, "rev-parse", "--verify", "refs/heads/" + name)
    if not sha:
        return False
    if git(repo, "for-each-ref", "--count=1", "--contains", sha, "refs/remotes"):
        return True
    return any(name != base and subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", sha, "refs/heads/" + base],
        capture_output=True, timeout=5).returncode == 0 for base in ("main", "master"))


def worktree_target(repo, value):
    target = directory(value, repo)
    if not target or ".." in Path(value).parts or target.is_symlink():
        return False
    parts = target.parts
    if any(parts[i:i + 2] == (".claude", "worktrees") for i in range(len(parts) - 2)):
        return True
    # 名前に依存せず git に登録された worktree も対象にする。主作業ツリーは含めない。
    roots = [line[9:] for line in git(repo, "worktree", "list", "--porcelain").splitlines()
             if line.startswith("worktree ")]
    return any(target == Path(root).resolve() for root in roots[1:])


def stash_drop_allowed(repo, args):
    """drop する stash の変更がすべて HEAD に入っていて、消しても git から戻せるときだけ True。"""
    refs = [arg for arg in args[2:] if arg not in {"-q", "--quiet"}]
    if len(refs) > 1:
        return False
    ref = refs[0] if refs else "stash@{0}"
    if ref.isdigit():
        ref = "stash@{" + ref + "}"
    # 番号は別セッションの stash push でずれるので、実在しない・組み立てた参照は判定しない。
    if not (ref.startswith("stash@{") and ref.endswith("}") and ref[7:-1].isdigit()):
        return False
    if not git(repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}"):
        return False
    # -u / -a の stash は未追跡ファイルを第 3 親に持ち、HEAD に控えが無い。
    if git(repo, "rev-parse", "--verify", "--quiet", ref + "^3"):
        return False
    paths = git(repo, "diff", "--name-only", "-z", ref + "^1", ref).split("\0")
    paths = [path for path in paths if path]
    if not paths:
        return True
    # 作業ツリーの最終状態だけを見る。stage 途中の状態 (第 2 親) は控えの対象にしない。
    result = subprocess.run(["git", "-C", str(repo), "diff", "--quiet", ref, "HEAD", "--", *paths],
                            capture_output=True, timeout=5,
                            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0", "GIT_LITERAL_PATHSPECS": "1"})
    return result.returncode == 0


def evaluate(payload):
    if payload.get("tool_name") != "Bash":
        return {}
    command = payload.get("tool_input", {}).get("command", "")
    if not any(word in command for word in ("git", "rm")):
        return {}
    event = payload.get("hook_event_name", "PreToolUse")
    state = state_dir(payload)
    cwd = Path(payload.get("cwd") or os.getcwd())
    parsed = list(commands(command, cwd))
    creations = []
    approved = bool(parsed)
    for repo, argv in parsed:
        git_repo, args = git_command(repo, argv)
        operation, names = branch_operation(args)
        if operation == "delete":
            if not git_repo or not names or not all(branch_allowed(state, git_repo, name) for name in names):
                if event == "PreToolUse":
                    return {"hookSpecificOutput": {"hookEventName": event, "permissionDecision": "deny",
                            "permissionDecisionReason": "このセッションで作成した記録も、push・取り込み済みの記録もないブランチは削除できません。"}}
                approved = False
        elif args[:2] == ["stash", "drop"]:
            if not git_repo or not stash_drop_allowed(git_repo, args):
                if event == "PreToolUse":
                    return {"hookSpecificOutput": {"hookEventName": event, "permissionDecision": "deny",
                            "permissionDecisionReason": "drop する stash の変更が HEAD に入っておらず、消すと git から戻せません（未追跡ファイルを含む stash、存在しない・組み立てた参照も含む）。不要か確かめたうえで、ユーザーに手で消してもらってください。"}}
                approved = False
        elif operation == "create" and git_repo:
            creations.extend((str(git_repo), name) for name in names if literal(name))
            approved = False
        elif argv[0] == "rm" and repo:
            targets = [arg for arg in argv[1:] if not arg.startswith("-")]
            approved = approved and bool(targets) and all(worktree_target(repo, name) for name in targets)
        elif args[:2] == ["worktree", "remove"] and git_repo:
            targets = [arg for arg in args[2:] if not arg.startswith("-")]
            approved = approved and len(targets) == 1 and worktree_target(git_repo, targets[0])
        else:
            approved = False
    if event == "PermissionRequest":
        return {"hookSpecificOutput": {"hookEventName": event, "decision": {"behavior": "allow"}}} if approved else {}
    if state and creations and payload.get("tool_use_id"):
        pending = state / ("tool-" + key(payload["tool_use_id"]) + ".json")
        if event == "PreToolUse":
            write_state(pending, [[repo, name] for repo, name in creations
                                  if not git(repo, "rev-parse", "--verify", "refs/heads/" + name)])
        elif event == "PostToolUse":
            result = payload.get("tool_response", {})
            failed = isinstance(result, dict) and (result.get("exit_code", 0) != 0
                       or result.get("interrupted") or result.get("is_error")
                       or "fatal:" in (result.get("stderr") or ""))
            if not failed:
                for repo, name in read_state(pending) or []:
                    identity = branch_identity(Path(repo), name)
                    if identity:
                        write_state(owned_path(state, Path(repo), name), identity)
            pending.unlink(missing_ok=True)
    return {}


if __name__ == "__main__":
    payload = {}
    try:
        payload = json.load(sys.stdin)
        response = evaluate(payload)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        # 判定不能を許可扱いにしない。通常コマンドは冒頭で対象外になる。
        reason = "後片付けの許可判定に失敗しました: " + str(error)
        if payload.get("hook_event_name") == "PermissionRequest":
            response = {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                        "decision": {"behavior": "deny", "message": reason}}}
        else:
            response = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                        "permissionDecisionReason": reason}}
    if response:
        print(json.dumps(response, ensure_ascii=False))
