#!/usr/bin/env -S uv run --no-project --offline
"""Claude Code の PreToolUse hook。読み取りだけと機械的に判定できた gcloud コマンドを allow する。

settings の allow ルール `Bash(gcloud * list)` は `*` が subcommand の前にあり、
`gcloud run services delete foo --filter list` にも一致してしまう。そのため allow ルールは
明示列挙に絞り、列挙外の group の読み取りをこの hook が動詞解析で補う。

- allow は「すべての条件を満たしたとき」だけ返す。deny / ask は返さない。判定に迷うものは
  無出力（exit 0）にして、通常の permission フロー（auto mode の classifier）に任せる。
  settings の deny / ask ルールは hook の結果に関わらず評価されるので、allow を返しても迂回にならない。
- hook の allow はコマンド文字列全体に効く。複合コマンドは一部が読み取りでも通さず、
  全セグメントが「gcloud 読み取り」か「出力を絞るだけのフィルタ」であるときだけ allow する。
- `gcloud --impersonate-service-account=x ...` のような動詞より前のオプションは、
  権限の借用や設定の上書きを伴うので拒む（動詞の位置が正しく取れなくなる点でも危険）。
- `$`・バッククォート・改行・リダイレクト・`&` は実行内容を静的に確定できないため無出力にする。
- 入力が壊れていても hook の失敗で作業を止めないため、常に exit 0 で終わる。
"""

import json
import re
import shlex
import sys

READ_VERBS = {"list", "describe", "get", "get-iam-policy", "get-value", "read", "ls"}

# 動詞より前（group 名の位置）に現れたら読み取りとみなさない語。
MUTATING_WORDS = {
    "create", "delete", "update", "deploy", "set", "add", "remove", "import", "export",
    "enable", "disable", "execute", "run", "ssh", "scp", "start", "stop", "restart",
    "reset", "resume", "suspend", "cancel", "rollback", "submit", "apply", "login",
    "revoke", "activate", "install", "attach", "detach", "connect", "proxy", "cp", "mv",
    "rm", "patch", "replace", "upload", "download", "publish", "pull", "invoke", "call",
    "access", "add-iam-policy-binding", "remove-iam-policy-binding", "set-iam-policy",
    "print-access-token", "print-identity-token", "get-credentials",
}  # fmt: skip

FILTER_COMMANDS = {"head", "tail", "grep", "wc", "cut", "uniq", "jq", "sort"}
SEPARATORS = {"|", "&&", "||", ";"}
MAX_WORDS_BEFORE_VERB = 5

HARMLESS_REDIRECT = re.compile(r"(?<!\S)2>(?:&1|/dev/null)(?!\S)")


def tokenize(command: str) -> list[str] | None:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        return None


def is_filter(words: list[str]) -> bool:
    if words[0] not in FILTER_COMMANDS:
        return False
    # sort -o はファイルを書き込める
    if words[0] == "sort" and any(w == "-o" or w.startswith("--output") or re.fullmatch(r"-[a-zA-Z]*o\S*", w) for w in words):
        return False
    return True


def is_gcloud_read(words: list[str]) -> bool:
    if words[0] != "gcloud":
        return False
    # 認証ヘッダを出力する
    if any(w.startswith("--log-http") for w in words):
        return False

    rest = words[1:]
    if rest and rest[0] in {"alpha", "beta"}:
        rest = rest[1:]

    for index, word in enumerate(rest):
        if word.startswith("-"):
            return False
        if index > MAX_WORDS_BEFORE_VERB:
            return False
        if word in READ_VERBS:
            return True
        # `gcloud run ...` の run は Cloud Run の group 名であって実行動詞ではない
        is_cloud_run_group = index == 0 and word == "run"
        if word in MUTATING_WORDS and not is_cloud_run_group:
            return False
    return False


def is_readonly(command: str) -> bool:
    if "$" in command or "`" in command or "\n" in command or "\r" in command:
        return False

    tokens = tokenize(HARMLESS_REDIRECT.sub(" ", command))
    if not tokens:
        return False

    segments: list[list[str]] = [[]]
    for token in tokens:
        if token in SEPARATORS:
            segments.append([])
        elif token and all(c in "();<>|&" for c in token):
            return False
        else:
            segments[-1].append(token)

    if any(not segment for segment in segments):
        return False
    if not any(segment[0] == "gcloud" for segment in segments):
        return False
    return all(is_gcloud_read(s) or is_filter(s) for s in segments)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    if not isinstance(payload, dict) or payload.get("tool_name") != "Bash":
        return 0
    tool_input = payload.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not is_readonly(command):
        return 0

    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": "gcloud の読み取り専用コマンドと判定したため許可",
                }
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
