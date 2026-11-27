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

    def assertAxesSumToTotal(self, report: ac.Report) -> None:
        self.assertAlmostEqual(sum(report.by_agent.values()), report.total)
        self.assertAlmostEqual(sum(report.by_project.values()), report.total)
        self.assertAlmostEqual(sum(report.by_model.values()), report.total)
        self.assertAlmostEqual(sum(report.by_kind.values()), report.total)

    def test_エージェント別はmainとサブエージェントの型ごとに分け型不明は1つにまとめる(self) -> None:
        self.write("p/s.jsonl", [row("claude-opus-5-5", usage(out=1_000_000), mid="main")])
        self.write("p/s/subagents/agent-a.jsonl", [row("claude-opus-5-5", usage(out=2_000_000), mid="a")])
        (self.root / "p/s/subagents/agent-a.meta.json").write_text(json.dumps({"agentType": "Explore"}), encoding="utf-8")
        self.write("p/s/subagents/agent-b.jsonl", [row("claude-opus-5-5", usage(out=1_000_000), mid="b")])
        self.write("p/s/subagents/agent-c.jsonl", [row("claude-opus-5-5", usage(out=1_000_000), mid="c")])
        (self.root / "p/s/subagents/agent-c.meta.json").write_text(json.dumps({"description": "無名"}), encoding="utf-8")

        report = self.run_period()

        self.assertEqual(report.by_agent.keys(), {"main", "Explore", "subagent(不明)"})
        self.assertAlmostEqual(report.by_agent["main"], 20)
        self.assertAlmostEqual(report.by_agent["Explore"], 40)
        self.assertAlmostEqual(report.by_agent["subagent(不明)"], 40)
        self.assertAxesSumToTotal(report)

    def test_プロジェクト別はprojects直下のディレクトリ名ごとに分ける(self) -> None:
        self.write("alpha/s.jsonl", [row("claude-opus-5-5", usage(out=1_000_000), mid="a")])
        self.write("beta/s/subagents/agent-x.jsonl", [row("claude-opus-5-5", usage(out=3_000_000), mid="b")])

        report = self.run_period()

        self.assertAlmostEqual(report.by_project["alpha"], 20)
        self.assertAlmostEqual(report.by_project["beta"], 60)
        self.assertAxesSumToTotal(report)

    def test_重複除去の勝った行の場所で全ての軸を数える(self) -> None:
        # 同じ応答が2つのプロジェクトに写った場合、ソート順で後のファイルの行（out=2M）だけを数える
        self.write("p1/s.jsonl", [row("claude-opus-5-5", usage(out=1_000_000), mid="m", rid="r")])
        self.write("p2/s.jsonl", [row("claude-opus-5-5", usage(out=2_000_000), mid="m", rid="r")])

        report = self.run_period()

        self.assertAlmostEqual(report.total, 40)
        self.assertEqual(report.by_project, {"p2": 40})
        self.assertEqual(report.responses, 1)
        self.assertAxesSumToTotal(report)

    def test_金額の高いセッション上位5件はサブエージェントを親に含めて並べる(self) -> None:
        for i in range(1, 7):
            self.write(f"p/s{i}.jsonl", [row("claude-opus-5-5", usage(out=i * 1_000_000), mid=f"m{i}")])
        # s1 にサブエージェントを足すと、親セッションの金額が上位に入る
        self.write("p/s1/subagents/agent-x.jsonl", [row("claude-opus-5-5", usage(out=10_000_000), mid="sub")])

        report = self.run_period()

        self.assertEqual(len(report.top_sessions), 5)
        self.assertEqual([s["session_id"] for s in report.top_sessions], ["s1", "s6", "s5", "s4", "s3"])
        self.assertEqual(report.top_sessions[0]["project"], "p")
        self.assertAlmostEqual(report.top_sessions[0]["cost"], 220)
        self.assertEqual(report.top_sessions[0]["responses"], 2)

    def test_1応答あたりのキャッシュ読みは全応答の読みトークンの平均(self) -> None:
        self.write(
            "p/s.jsonl",
            [
                row("claude-opus-5-5", usage(read=1_000_000), mid="a"),
                row("claude-opus-5-5", usage(read=3_000_000), mid="b"),
            ],
        )

        report = self.run_period()

        self.assertAlmostEqual(report.cache_read_per_response, 2_000_000)

    def test_daysは今日を含む直近N日を期間にする(self) -> None:
        self.assertEqual(ac.period_of_days(7, date(2026, 11, 27)), (date(2026, 11, 21), date(2026, 11, 27)))
        self.assertEqual(ac.period_of_days(1, date(2026, 11, 27)), (date(2026, 11, 27), date(2026, 11, 27)))


if __name__ == "__main__":
    unittest.main()
