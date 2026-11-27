# worker の力量の目安（実測）

task の大きさと書き込みの細かさを決めるための観察。agent の種類で rule・完了条件・レビュー基準は変えない
（SKILL.md の原則）。ここに書くのは「1 task をどこまで割るか」「task に何を名指しするか」の目安だけ。
観察はモデルと確認日つきで足し、モデルが変わったら測り直す。

## pi（openai gpt-6-luna、medium） 2026-10-18

ある Web アプリの repo で 10 回ほど投函して見えたこと。

| 観察 | 実例 | 効いた対処 |
|---|---|---|
| 範囲が広いと手を付けずに「未着手」でブロックする | 9 ゴールの画面 task（Session 一覧・チャット・入力欄・vendor 10 ファイル）、「必要なファイルを vendor して」 | 必須テスト 2〜3 本の task に割り直す（B1 / B2a / B2b / B3） |
| 最初の障害で止まる | `pnpm init` の `devEngines` による pnpm の自動 download が sandbox で失敗、`ERR_PNPM_IGNORED_BUILDS`、`runAgentLoop` の import 先の読み違え（「subpath だけ」を別パッケージにも当てた）、テストの日付が ISO でない | task に「最初の障害で止めない」「迷ったら単純な方」と書く。依存の install は orchestrator が先に済ませる |
| 実装は入れても指定のテストを書かずに返す | SSE・履歴・失敗の受入テスト 5 本が未作成のまま | テストの部品とコード例を task に書く（pi-ai の faux provider で偽の LLM を作る例）と書けた |
| 報告は正直で、未実施は未実施と書く | 「RED→GREEN は確認していない」「未着手」 | report を信じてよいが、`check_delivery` の pass だけで完了と見ない |
| 後片付けを忘れる | dev server（ポート 5173）を握ったまま pane が終了 | レビュー時に orchestrator が止める |

効いた task の形:
- 1 task = 必須テスト 2〜3 本。写すファイル・API の形・テスト名・ログのパスを名指しする
- 前回のブロックへの「裁定」を冒頭に書き、続きの task は同じ pane に投函する（文脈が健全な間）
- 残った小さな仕上げ（判断の要らないテストの補い、format、lint 1 件、テストデータの誤り）は、差し戻すより orchestrator が直す方が速かった。範囲は SKILL.md の「orchestrator が自分で行うのは」の目安に従う


- 判断の多いライブラリの model 操作は worker に割らない。codex の worker に判断の多いライブラリの model 編集
  を割ると、小さく割っても止まる・未着手で返すことが続き、主エージェントが自分で書いた方が速かった。
