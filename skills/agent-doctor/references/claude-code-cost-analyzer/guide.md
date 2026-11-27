<!-- 元は skill `claude-code-cost-analyzer`。相対パスはこのディレクトリが基準 -->

# claude-code-cost-analyzer

定額プラン（Pro / Max / Team）の枠で使った Claude Code の利用を、従量課金（Enterprise の利用分・API 直契約）の定価なら幾らになるかに換算する。
計算は `scripts/api_cost.py` が全部持つ。依存は Python 標準ライブラリだけ。

## 手順

1. 期間を決める。ユーザーの指定が無ければ、今月の1日から今日までにする。
   Claude Code は既定で30日を過ぎたログを消すので（`cleanupPeriodDays`）、それより前は残っていないことがある。
2. 実行する。

   ```sh
   uv run references/claude-code-cost-analyzer/scripts/api_cost.py --since 2026-10-01 --until 2026-10-28
   ```

   - `uv` が無ければ `python3 <同じパス> ...` で動く（3.11 以上）。
   - 期間は日本時間の暦日で切る。別のタイムゾーンなら `--tz America/Los_Angeles` のように渡す。
   - ログの場所が違えば `--projects-dir`。`CLAUDE_CONFIG_DIR` が設定されていればその下の `projects/` を見る。
   - 資料に数字を貼るときは `--json` で取る。
3. 結果を報告する。合計、稼働日1日あたり、モデル別、種別の内訳をそのまま出し、次の前提を添える。
   - 単価は API の定価で、全社契約の割引・税は含まない。
   - この端末のログだけ。ほかの PC や claude.ai・デスクトップアプリでの利用は入らない。
   - web 検索などのサーバーツールの従量料金は入らない。

## 終了コード 2 で止まったとき

`error: 単価表に無いモデル` が出たら、新しいモデルが出て単価表が古い。推測した単価で計算し直さない。
公式の料金ページ（https://platform.claude.com/docs/en/about-claude/pricing）の Model pricing 表から、
そのモデルの5つの値を `PRICES` に足し、`PRICES` の上にある取得日も更新してから実行し直す。
単価が改定されたときも同じ手順で表を直す。

## 数え方（変えるときはテストも直す）

`tests/test_api_cost.py` が正本。要点だけ書く。

- 同じ応答は `message.id` と `requestId` の組で1回だけ数える。Claude Code は1つの応答を複数行に書き、resume すると別ファイルにも写すため、重複を除かないと倍以上になる。
- キャッシュ書き込みは5分と1時間で単価が違うので、`usage.cache_creation` の内訳で分ける。
- advisor を使った応答は、advisor の分が上位の `usage` に入っておらず、`usage.iterations` の `advisor_message`（advisor のモデル付き）にだけある。iterations があれば回ごとにそのモデルの単価で数える。
- Haiku 5.5 は、1回の入力（キャッシュの読み書きを含む）が10万トークンを超えたリクエストだけ高い単価になる。
- `speed: fast` は fast mode の単価、`inference_geo: us` は 1.1 倍で数える。
- `subagents/` のログも含める。

テストの実行: `uv run --no-project python -I -m unittest discover -s references/claude-code-cost-analyzer/tests`
