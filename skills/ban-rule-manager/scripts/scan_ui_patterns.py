#!/usr/bin/env python3
"""ui-banned-pattern.json のルールを対象repoの既存ファイルへ遡及適用し、違反を一覧化する。

hookが防げるのは「これから書かれる」違反だけなので、hook導入前や他エージェント
(Claude以外)が書いたコードにはこのscriptで遡及スキャンをかける。実際の削除・置換は
判断が要るため、ここでは file:line の一覧化までに留め、rule の skill 欄が指す skill へ誘導する。

Usage:
  uv run --no-project scripts/scan_ui_patterns.py <target_dir> <registry_path>
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys

EXCLUDE_DIRS = {"node_modules", ".next", "dist", "build", ".venv", "__pycache__"}


def load_rules(registry_path: str) -> list[dict]:
    with open(registry_path, encoding="utf-8") as f:
        return json.load(f)["rules"]


def iter_files(root: str, extensions: set[str] | None):
    # extensions が None のときは拡張子で絞らず全ファイルを返す (path_patterns だけの rule 用)
    if shutil.which("rg"):
        globs: list[str] = []
        for ext in extensions or []:
            globs += ["-g", f"*.{ext}"]
        try:
            proc = subprocess.run(
                ["rg", "--files", *globs],
                cwd=root,
                capture_output=True,
                text=True,
                check=True,
            )
            for line in proc.stdout.splitlines():
                yield os.path.join(root, line)
            return
        except (subprocess.CalledProcessError, OSError):
            pass  # rg 失敗時は os.walk にフォールバック

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS and not d.startswith(".")]
        for fn in filenames:
            ext = fn.rsplit(".", 1)[-1] if "." in fn else ""
            if extensions is None or ext in extensions:
                yield os.path.join(dirpath, fn)


def scan(root: str, registry_path: str) -> list[dict]:
    findings: list[dict] = []
    for rule in load_rules(registry_path):
        extensions = set(rule.get("extensions") or [])
        path_patterns = [re.compile(p) for p in rule.get("path_patterns") or []]
        if not extensions and not path_patterns:
            # v1: 拡張子もパスも絞らないルールは遡及スキャン非対応。
            # 対象を絞れないと誤検知が広がりすぎるため、意図的にスキップする。
            continue
        deny = [re.compile(p, re.IGNORECASE) for p in rule["deny_patterns"]]
        allow = [re.compile(p, re.IGNORECASE) for p in rule.get("allow_patterns") or []]

        for path in iter_files(root, extensions or None):
            # path_patterns は hook と同じく ERE でパスに当て、どれか 1 つに当たれば対象にする
            if path_patterns and not any(p.search(path) for p in path_patterns):
                continue
            try:
                with open(path, encoding="utf-8", errors="ignore") as f:
                    lines = f.readlines()
            except OSError:
                continue
            for lineno, line in enumerate(lines, start=1):
                if any(p.search(line) for p in deny) and not any(p.search(line) for p in allow):
                    findings.append(
                        {
                            "rule": rule["id"],
                            "skill": rule.get("skill"),
                            "file": os.path.relpath(path, root),
                            "line": lineno,
                            "text": line.strip(),
                        }
                    )
    return findings


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("使い方: scan_ui_patterns.py <target_dir> <registry_path>（registry は ui-banned-pattern.json）")
    root, registry_path = sys.argv[1], sys.argv[2]

    findings = scan(root, registry_path)
    if not findings:
        print("違反なし")
        return

    by_rule: dict[str, list[dict]] = {}
    for f in findings:
        by_rule.setdefault(f["rule"], []).append(f)

    for rule_id, items in by_rule.items():
        skill = items[0]["skill"]
        header = f"## {rule_id} ({len(items)}件)"
        if skill:
            header += f" -> 修正は `{skill}` skill を使う"
        print(header)
        for it in items:
            print(f"  {it['file']}:{it['line']}: {it['text']}")
        print()


if __name__ == "__main__":
    main()
