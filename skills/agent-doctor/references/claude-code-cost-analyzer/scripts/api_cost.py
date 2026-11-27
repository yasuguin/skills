#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Claude Code の会話ログ（~/.claude/projects/**/*.jsonl）のトークン数を、Claude API の定価で金額に換算する。
定額プラン（Pro / Max / Team）で使った分が、従量課金（Enterprise の利用分・API）なら幾らになるかを見る読み取り専用の集計。

対象: projects ディレクトリ配下の *.jsonl（subagents/ を含む）。ファイルへの書き込みはしない。
期間は --tz の暦日で切る（既定は日本時間）。

使い方:
  uv run api_cost.py --since 2026-10-01 --until 2026-10-28 [--projects-dir DIR] [--tz Asia/Tokyo] [--json]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

# 単価（USD / 100万トークン）。出典: https://platform.claude.com/docs/en/about-claude/pricing（2026-11-12 取得）
# 並びは (入力, キャッシュ書き込み5分, キャッシュ書き込み1時間, キャッシュ読み, 出力)。
# キャッシュ読みの倍率はモデルで違う（Fable 5.2・Fable 5.1 は 0.025x、Opus 5.5・Sonnet 5.5 は 0.05x、他は 0.1x）ので、倍率で計算せず表に持つ。
PRICES: dict[str, tuple[float, float, float, float, float]] = {
    "claude-fable-5-2": (8, 10, 16, 0.20, 40),
    "claude-fable-5-1": (10, 12.50, 20, 0.25, 50),
    "claude-mythos-5-1": (10, 12.50, 20, 0.25, 50),
    "claude-fable-5": (10, 12.50, 20, 1, 50),
    "claude-mythos-5": (10, 12.50, 20, 1, 50),
    "claude-opus-5-5": (4, 5, 8, 0.20, 20),
    "claude-opus-5": (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-8": (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-7": (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-6": (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-5": (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-1": (15, 18.75, 30, 1.50, 75),
    "claude-opus-4": (15, 18.75, 30, 1.50, 75),
    "claude-sonnet-5-5": (2, 2.50, 4, 0.10, 10),
    "claude-sonnet-5": (2, 2.50, 4, 0.20, 10),
    "claude-sonnet-4-6": (3, 3.75, 6, 0.30, 15),
    "claude-sonnet-4-5": (3, 3.75, 6, 0.30, 15),
    "claude-sonnet-4": (3, 3.75, 6, 0.30, 15),
    "claude-haiku-5-5": (0.10, 0.125, 0.20, 0.01, 0.50),
    "claude-haiku-4-5": (1, 1.25, 2, 0.10, 5),
    "claude-haiku-3-5": (0.80, 1, 1.60, 0.08, 4),
}
# Haiku 5.5 だけは、1回の入力（キャッシュ読み・書き込みを含む）が10万トークンを超えると、そのリクエスト全体が高い単価になる。
HAIKU_55_LONG = (0.50, 0.625, 1, 0.05, 2.50)
HAIKU_55_THRESHOLD = 100_000
# fast mode の入力・出力単価。キャッシュの倍率（5分 1.25x・1時間 2x・読み 0.05x）はこの上に掛かる。
FAST = {"claude-fable-5-2": (16, 80, 0.025), "claude-opus-5-5": (8, 40, 0.05), "claude-opus-5": (10, 50, 0.1), "claude-opus-4-8": (10, 50, 0.1)}
# inference_geo が us（US 限定推論）だと全種別に 1.1 倍が掛かる。
US_GEO_MULTIPLIER = 1.1

KINDS = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output")
DATE_SUFFIX = re.compile(r"-\d{8}$")


class UnpricedUsage(Exception):
    """単価表に無いモデルや課金形態があった。推測で値を当てず、単価表の更新を求める。"""


@dataclass
class Report:
    total: float = 0.0
    by_model: dict[str, float] = field(default_factory=dict)
    by_kind: dict[str, float] = field(default_factory=lambda: dict.fromkeys(KINDS, 0.0))
    tokens_by_kind: dict[str, int] = field(default_factory=lambda: dict.fromkeys(KINDS, 0))
    active_days: int = 0
    responses: int = 0


def normalize_model(model: str) -> str:
    return DATE_SUFFIX.sub("", model)


def token_counts(u: dict) -> dict[str, int]:
    cc = u.get("cache_creation") or {}
    w5 = cc.get("ephemeral_5m_input_tokens")
    w1 = cc.get("ephemeral_1h_input_tokens")
    if w5 is None and w1 is None:
        # 内訳の無い古いログは、Claude Code の既定 TTL である5分として数える
        w5, w1 = u.get("cache_creation_input_tokens") or 0, 0
    return {
        "input": u.get("input_tokens") or 0,
        "cache_write_5m": w5 or 0,
        "cache_write_1h": w1 or 0,
        "cache_read": u.get("cache_read_input_tokens") or 0,
        "output": u.get("output_tokens") or 0,
    }


def unit_prices(model: str, tokens: dict[str, int], speed: str | None, geo: str | None) -> tuple[float, ...]:
    if speed not in (None, "standard"):
        if speed != "fast" or model not in FAST:
            raise UnpricedUsage(f"{model} の speed={speed} の単価が単価表に無い")
        inp, out, read_ratio = FAST[model]
        prices: tuple[float, ...] = (inp, inp * 1.25, inp * 2, inp * read_ratio, out)
    elif model == "claude-haiku-5-5":
        prompt = tokens["input"] + tokens["cache_write_5m"] + tokens["cache_write_1h"] + tokens["cache_read"]
        prices = HAIKU_55_LONG if prompt > HAIKU_55_THRESHOLD else PRICES[model]
    elif model in PRICES:
        prices = PRICES[model]
    else:
        raise UnpricedUsage(f"単価表に無いモデル: {model}（scripts/api_cost.py の PRICES に公式の料金ページから足す）")
    if geo == "us":
        prices = tuple(p * US_GEO_MULTIPLIER for p in prices)
    return prices


def priced_parts(message_model: str, u: dict) -> list[tuple[str, dict[str, int], tuple[float, ...]]]:
    """1つの応答を (モデル, トークン数, 単価) に分ける。

    advisor を使った応答は usage.iterations に executor の各回（type: message）と advisor の回
    （type: advisor_message、model 付き）が並び、上位の usage には advisor の分が入っていない。
    回ごとに別リクエストとして値段が付くので、iterations があれば回ごとに数える。
    """
    speed, geo = u.get("speed"), u.get("inference_geo")
    iterations = u.get("iterations") or [u]
    parts = []
    for it in iterations:
        model = normalize_model(it.get("model") or message_model)
        tokens = token_counts(it)
        # fast mode は executor のリクエストの設定で、advisor の回には掛からない
        it_speed = None if it.get("type") == "advisor_message" else speed
        parts.append((model, tokens, unit_prices(model, tokens, it_speed, geo)))
    return parts


def iter_responses(projects_dir: Path):
    """(message.id, requestId) ごとに最後の行を返す。

    Claude Code は1つの応答を content block ごとに複数行書き、resume すると別ファイルにも同じ応答を写す。
    数え直さないよう組で重複を除き、出力トークンは書き終えた最後の行の値を使う。
    """
    latest: dict[tuple[str, str], dict] = {}
    for path in sorted(projects_dir.rglob("*.jsonl")):
        with path.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"assistant"' not in line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                message = row.get("message") or {}
                if row.get("type") != "assistant" or not message.get("usage"):
                    continue
                latest[(message.get("id"), row.get("requestId"))] = row
    return latest.values()


def analyze(projects_dir: Path, since: date, until: date, tz: ZoneInfo = ZoneInfo("Asia/Tokyo")) -> Report:
    report = Report()
    days: set[date] = set()
    for row in iter_responses(projects_dir):
        message = row["message"]
        if message.get("model") in (None, "<synthetic>"):
            continue
        day = datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")).astimezone(tz).date()
        if not since <= day <= until:
            continue
        days.add(day)
        report.responses += 1
        for model, tokens, prices in priced_parts(message["model"], message["usage"]):
            for kind, price in zip(KINDS, prices):
                cost = tokens[kind] * price / 1_000_000
                report.total += cost
                report.by_kind[kind] += cost
                report.tokens_by_kind[kind] += tokens[kind]
                report.by_model[model] = report.by_model.get(model, 0.0) + cost
    report.active_days = len(days)
    return report


KIND_LABELS = {
    "input": "入力",
    "cache_write_5m": "キャッシュ書き込み（5分）",
    "cache_write_1h": "キャッシュ書き込み（1時間）",
    "cache_read": "キャッシュ読み",
    "output": "出力",
}


def render(report: Report, since: date, until: date) -> str:
    lines = [
        f"期間: {since} 〜 {until}（稼働 {report.active_days} 日、応答 {report.responses:,} 件）",
        f"API 定価での換算: ${report.total:,.2f}",
    ]
    if report.active_days:
        lines.append(f"稼働日1日あたり: ${report.total / report.active_days:,.2f}")
    lines += ["", "モデル別:"]
    for model, cost in sorted(report.by_model.items(), key=lambda kv: -kv[1]):
        lines.append(f"  {model:<22} ${cost:>12,.2f}")
    lines += ["", "種別:"]
    for kind in KINDS:
        lines.append(
            f"  {KIND_LABELS[kind]:<16} ${report.by_kind[kind]:>12,.2f}  ({report.tokens_by_kind[kind]:,} トークン)"
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--since", type=date.fromisoformat, required=True, help="開始日（含む）YYYY-MM-DD")
    parser.add_argument("--until", type=date.fromisoformat, required=True, help="終了日（含む）YYYY-MM-DD")
    default_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude")) / "projects"
    parser.add_argument("--projects-dir", type=Path, default=default_dir)
    parser.add_argument("--tz", default="Asia/Tokyo", help="期間を切る暦日のタイムゾーン")
    parser.add_argument("--json", action="store_true", help="JSON で出す")
    args = parser.parse_args()

    try:
        report = analyze(args.projects_dir, args.since, args.until, ZoneInfo(args.tz))
    except UnpricedUsage as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({"since": str(args.since), "until": str(args.until), **report.__dict__}, ensure_ascii=False, indent=2))
    else:
        print(render(report, args.since, args.until))
    return 0


if __name__ == "__main__":
    sys.exit(main())
