from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

import api_cost as ac  # noqa: E402


def usage(inp=0, out=0, read=0, w5=0, w1=0, **extra) -> dict:
    return {
        "input_tokens": inp,
        "output_tokens": out,
        "cache_read_input_tokens": read,
        "cache_creation_input_tokens": w5 + w1,
        "cache_creation": {"ephemeral_5m_input_tokens": w5, "ephemeral_1h_input_tokens": w1},
        **extra,
    }


def row(model: str, u: dict, *, mid="msg_1", rid="req_1", ts="2026-10-10T03:00:00.000Z") -> dict:
    return {
        "type": "assistant",
        "timestamp": ts,
        "requestId": rid,
        "message": {"id": mid, "model": model, "usage": u},
    }


class ApiCostTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, rel: str, rows: list[dict]) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")

    def run_period(self, since=date(2026, 10, 1), until=date(2026, 10, 31)) -> ac.Report:
        return ac.analyze(self.root, since, until)

    def test_トークン種別ごとに定価を掛けてキャッシュ書き込みは5分と1時間を分ける(self) -> None:
        # Opus 5.5: 入力 $4 / 出力 $20 / 読み $0.20 / 5分 $5 / 1時間 $8（100万トークンあたり）
        self.write("p/s.jsonl", [row("claude-opus-5-5", usage(1_000_000, 1_000_000, 1_000_000, 1_000_000, 1_000_000))])

        report = self.run_period()

        self.assertAlmostEqual(report.total, 4 + 20 + 0.20 + 5 + 8)
        self.assertAlmostEqual(report.by_kind["cache_write_1h"], 8)

    def test_同じ応答の重複行は1回だけ数え最後の行の値を使う(self) -> None:
        self.write(
            "p/s.jsonl",
            [
                row("claude-opus-5-5", usage(out=1_000_000)),
                row("claude-opus-5-5", usage(out=2_000_000)),
            ],
        )
        # resume で別ファイルに同じ応答が写った場合も重複として扱う
        self.write("p/other.jsonl", [row("claude-opus-5-5", usage(out=2_000_000))])

        report = self.run_period()

        self.assertAlmostEqual(report.total, 40)

    def test_advisorの分はiterationsのモデルの単価で別に足す(self) -> None:
        u = usage(out=1_000_000)
        u["iterations"] = [
            {**usage(out=1_000_000), "type": "message"},
            {**usage(inp=1_000_000), "type": "advisor_message", "model": "claude-fable-5-1"},
        ]
        self.write("p/s.jsonl", [row("claude-sonnet-5-5", u)])

        report = self.run_period()

        self.assertAlmostEqual(report.by_model["claude-sonnet-5-5"], 10)
        self.assertAlmostEqual(report.by_model["claude-fable-5-1"], 10)

    def test_Haiku55は1回の入力が10万トークンを超えると高い単価になる(self) -> None:
        self.write(
            "p/s.jsonl",
            [
                row("claude-haiku-5-5", usage(inp=1_000, read=99_000, out=1_000_000), mid="a"),
                row("claude-haiku-5-5", usage(inp=1_000, read=99_001, out=1_000_000), mid="b"),
            ],
        )

        report = self.run_period()

        small = 1_000 * 0.10 / 1e6 + 99_000 * 0.01 / 1e6 + 0.50
        large = 1_000 * 0.50 / 1e6 + 99_001 * 0.05 / 1e6 + 2.50
        self.assertAlmostEqual(report.total, small + large)

    def test_期間は日本時間で切りサブエージェントのログも含める(self) -> None:
        self.write(
            "p/s.jsonl",
            [
                # 日本時間 10/1 08:59 は 9/30 23:59 UTC
                row("claude-opus-5-5", usage(out=1_000_000), mid="in", ts="2026-09-30T23:59:00.000Z"),
                # 日本時間 9/30 23:59（期間外）
                row("claude-opus-5-5", usage(out=1_000_000), mid="out", ts="2026-09-30T14:59:00.000Z"),
            ],
        )
        self.write("p/s/subagents/agent-x.jsonl", [row("claude-opus-5-5", usage(out=1_000_000), mid="sub")])

        report = self.run_period(since=date(2026, 10, 1), until=date(2026, 10, 10))

        self.assertAlmostEqual(report.total, 40)
        self.assertEqual(report.active_days, 2)

    def test_日付つきのモデルIDは日付を外して単価を引きsyntheticは数えない(self) -> None:
        self.write(
            "p/s.jsonl",
            [
                row("claude-haiku-4-5-20251001", usage(out=1_000_000), mid="a"),
                row("<synthetic>", usage(out=1_000_000), mid="b"),
            ],
        )

        report = self.run_period()

        self.assertEqual(report.by_model, {"claude-haiku-4-5": 5})

    def test_単価表に無いモデルは推測せずに止める(self) -> None:
        self.write("p/s.jsonl", [row("claude-future-9", usage(out=1))])

        with self.assertRaises(ac.UnpricedUsage) as ctx:
            self.run_period()

        self.assertIn("claude-future-9", str(ctx.exception))

    def test_fast_modeとUS限定推論は単価に倍率を掛ける(self) -> None:
        self.write(
            "p/s.jsonl",
            [
                row("claude-opus-5-5", usage(out=1_000_000, speed="fast"), mid="fast"),
                row("claude-opus-5-5", usage(out=1_000_000, inference_geo="us"), mid="us"),
            ],
        )

        report = self.run_period()

        self.assertAlmostEqual(report.total, 40 + 20 * 1.1)


if __name__ == "__main__":
    unittest.main()
