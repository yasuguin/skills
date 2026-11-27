---
name: agent-doctor
description: "AI エージェント（Claude Code）の開発が遅い原因を診断する。会話ログを数値で集計して、時間の使い道（モデル応答・コンテキスト肥大・テスト・hook・Stop の block・ガードの拒否・委譲・質問の往復）を出し、hook を 1 本ずつ実測して、遅さを誘発しているルールの場所まで辿る。「なぜ遅いか診断して」「どこで時間を使っているか見て」「hook が遅い気がする」のような依頼で使う。承認された項目だけ直す。Claude Code の利用の API 料金換算も。"
disable-model-invocation: true
---

# agent-doctor

AI エージェントの開発環境を診断する。症状ではなく、それを生んでいるルールの場所
（`ファイル:行`）まで辿って直す。ルールを直さないと同じ問題が再発するため。

| モード | 使う場面 | 手順 |
| --- | --- | --- |
| 速度の診断 | 開発が遅い、どこで時間を使っているか知りたい | この下の「速度の診断」 |

ルールの直し方の方針: Claude Code の settings.json・hook・agent 定義と、Codex の rules・hook・profile、lint・test の機械的なルールを優先し、プロンプトでのルール制御は
最小限にする。prose に残すのは、機械的に判定できない判断の基準と理由だけ。

## 速度の診断

遅さの原因は感覚では外れやすい（「テストが遅い」と思ったら実はコンテキスト肥大と hook の往復だった）。
ログに残る時刻と回数で決める。

1. 集計する。既定は直近 7 日、全プロジェクト。

   ```bash
   uv run --no-project python -I scripts/analyze.py [--days 7] [--project <ディレクトリ名の一部>]
   ```

   結果は `~/.local/state/agent-doctor/` に保存され、前回の保存があれば冒頭に「前回比」が出る。
   細かい値が要るときは `--json`。

2. 冒頭の「自動で見つけた異常」を全件、原因の候補として必ず報告に入れる（無ければ「なし」と書く）。
   続けて時間の大きい順に原因を見立てる。指標ごとの読み方と、どのルールを疑うかは
   `references/diagnosis.md` を読む。1 つの数字だけで決めず、裏付けになる生ログ
   （`~/.claude/projects/**/*.jsonl`）を `jq` で 1〜2 件確かめてから原因と言う。

3. 実測する。ログの集計は「どこで待ったか」までで、hook や git hook の中のどの 1 本が遅いかは出ないので、
   必ず次を回してから原因と言う（2026-10-29、集計で見えた遅さの犯人は、どれも実測して初めて分かった）。
   - 測る前に `uptime` でロードアベレージを見る。コア数の数倍あると時間が膨らみ、比較が揺れで逆転する。
     その間は時間でなく、起動した子プロセスの数（`python -m cProfile` の `subprocess.run` の回数）で比べる。
   - ツール 1 回ごとに待つ hook を 1 本ずつ測る。同じイベントの hook は並列なので、待ちは一番遅い 1 本で決まる。

     ```bash
     uv run --no-project python -I scripts/measure_hooks.py [--tool Bash] [--command 'cat README.md']
     ```

   - 異常欄に「本来すぐ終わる `git commit` / `git push` が遅い」が出たら、その repo の git hook
     （`.githooks/`・`.husky/`・lefthook）の中の検査を 1 つずつ `time` で測り、桁違いの 1 本を探す。
     `pnpm <script>` 経由なら中身の `node …` を直接でも測る（pnpm の起動だけで約 2 秒かかった）。
   - 異常欄に「hook がタイムアウトに達した」が出たら、生ログからその tool_use の入力を取り出し、同じ入力で
     hook を流して再現する（`references/diagnosis.md` の「自動で見つけた異常」）。

4. 原因ごとに、誘発しているルールの場所を `ファイル:行` で示す。instruction file・skill・hook・settings の
   正本（配備先ではなく編集する元）を grep する。

5. 次の形で報告し、どれを直すかをユーザーに聞く。互いに影響しない選択は 1 回にまとめて聞いてよい。

   ```markdown
   ## 時間の内訳（直近 N 日、ターン合計 Xh）
   | 項目 | 合計 | 1 回あたり | 備考 |

   ## 原因（効いている順）
   ### 1. <原因>
   - 根拠: <数値>
   - 誘発しているルール: <ファイル:行>
   - 直し方の案: <案>（守りが弱くなるか・トレードオフ）
   ```

6. 承認された項目だけ直す。hook・script の振る舞いを変えるなら失敗するテストを先に書く。
   prose のルールを直すなら、上の「ルールの直し方の方針」に従う。
   方針の判断（守りの強さ、委譲の範囲、質問の粒度）はユーザーに聞いてから直す。

7. 直したら 3 の実測を回し直して効果を数字で示す。数日後にもう一度 1 を実行し、前回比でも確かめるよう案内する。

## 落とし穴

- ツールの時間には権限確認・auto mode の判定・hook の待ちが含まれ、`AskUserQuestion` はユーザーの
  回答待ちそのもの。遅さとして数えない。
- 集計期間には修正前の記録が混ざる。モデルの内訳や hook のエラーが修正後も残って見えたら、
  該当する設定ファイルの `git log` で変更日を確かめてから判断する。
- テストが環境（`ps` / `lsof` / SSH が使えない）で落ちても、失敗の中身を読まずに「環境のせい」と決めない。
  自分の変更で落ちたものが紛れる。落ちたテストだけに絞って再実行し、失敗の中身で見分ける。
- 作業ツリーに他セッションの未コミット変更があるので、`git stash` で退避しない。自分の差分は
  `git diff -- <編集したファイル>` で確かめる。
- transcript（`~/.claude/projects/**/*.jsonl`）を走査して使用実績を数えるときは、実行中セッション自身の transcript を除外する。
  自分が打った `grep` の引数に skill のパスが入り、「今日その skill が参照された」と誤検出した（2026-09-10）。
- skill 名の文字列一致は使用の証拠にならない（AGENTS.md の転載、skill 一覧、skill を編集したセッションに当たる）。数えるのは
  Skill dispatch（`~/.claude.json` の `skillUsage` にも残る）と、assistant の tool_use の `Read` で `file_path` が `skills/<name>/` のものだけ。
  `Edit` / `Write` は保守であって利用ではない。
- Claude Code の transcript は `cleanupPeriodDays`（既定 30 日）で消える。集計の窓は日数で報告し、薄いときは
  `skillUsage.lastUsedAt` の経過日数を併用する。Codex のログは長く残る。

## 関連する資料

- Claude Code の利用を API の定価に換算する: [references/claude-code-cost-analyzer/guide.md](references/claude-code-cost-analyzer/guide.md)

## 前提にしている skill

名前で呼ぶだけで、本文は写していない。入っていなければ入れる。

- `grilling`（[mattpocock/skills](https://github.com/mattpocock/skills)、MIT）: `npx skills@latest add mattpocock/skills --skill grilling`
