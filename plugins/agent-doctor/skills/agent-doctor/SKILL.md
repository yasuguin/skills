---
name: agent-doctor
description: AI エージェント（Claude Code・Codex）の開発環境を、ルール・速度・コストの面から診断し、症状を生んでいるルールの場所まで辿って直す。主役はルールの最適化で、instruction file・skill・autoMode の文章のルールを棚卸しし、settings.json・hook・agent 定義・Codex の rules・profile・lint・test の機械的な強制へ移す・重複を削る・強制とのずれを直す。速度の診断は会話ログの時刻と hook の実測で遅い原因（モデル応答・コンテキスト肥大・テスト・hook・ガードの拒否・委譲・質問の往復）を特定する。コストの診断は利用を API の定価に換算し、押し上げている内訳（サブエージェントの型・project・セッション・キャッシュ読み）から原因のルールを探す。「文章の決まりを hook・lint・test に移せるか点検して」「AGENTS.md を圧縮したい」「機械化できるルールが残っていないか精査して」「なぜ遅いか診断して」「API 料金に換算して」「コストが高い原因を見て」のような依頼で使う。承認された項目だけ直す。
disable-model-invocation: true
---

# agent-doctor

AI エージェントの開発環境を診断する。症状ではなく、それを生んでいるルールの場所
（`ファイル:行`）まで辿って直す。ルールを直さないと同じ問題が再発するため。

## ルールの直し方の方針

すべての面に共通する。Claude Code の settings.json・hook・agent 定義と、Codex の rules・hook・profile、
lint・test の機械的なルールを優先し、プロンプトでのルール制御は最小限にする。prose に残すのは、
機械的に判定できない判断の基準と理由だけ。文章のルールは読み飛ばされ、常時 prompt に載る分だけ
コンテキストと料金を食い、実際の強制とずれても誰も気づかない。

## 面

依頼の言葉から面を選ぶ。手がかりが無ければルールの最適化から始める。速度やコストの診断で
見つかった原因も、多くはルールの置き場所の問題に行き着く。

- **ルールの最適化**（主役）: prose のルールを機械的な強制へ移す、instruction file を圧縮する、
  書いてあることと実際の強制のずれを直す。手順は `references/rule-placement.md`。
- **速度の診断**: 開発が遅い、どこで時間を使っているか知りたい。手順は `references/speed.md`。
- **コストの診断**: API の定価に換算したい、料金を押し上げている原因を知りたい。手順は `references/cost.md`。

面を足すときは、ここに 1 行と `references/<面>.md` を足し、下の共通の流れに乗せる。

## 共通の流れ

1. 面の手順で棚卸し・集計・実測をする。数字や「強制済み」の判断は、生の根拠（ログ・grep・実測）で
   1〜2 件確かめてから原因と言う。
2. 原因ごとに、誘発しているルールの場所を `ファイル:行` で示す。instruction file・skill・hook・settings の
   正本（配備先ではなく編集する元）を grep する。
3. 次の形で報告し、どれを直すかをユーザーに聞く。互いに影響しない選択は 1 回にまとめて聞いてよい。
   面ごとの手順が、先頭に置く内訳（時間・金額・分類）を決める。

   ```markdown
   ## 原因（効いている順）
   ### 1. <原因>
   - 根拠: <数値・grep の結果>
   - 誘発しているルール: <ファイル:行>
   - 直し方の案: <案>（守りが弱くなるか・トレードオフ）
   ```

4. 承認された項目だけ直す。hook・script の振る舞いを変えるなら失敗するテストを先に書く。
   prose のルールを直すなら上の方針に従い、置き場所は `references/rule-placement.md` で決める。
   方針の判断（守りの強さ、委譲の範囲、質問の粒度）はユーザーに聞いてから直す。
5. 直したら、面の手順の集計・実測を回し直して効果を数字で示す。

## 落とし穴

- 作業ツリーに他セッションの未コミット変更があるので、`git stash` で退避しない。自分の差分は
  `git diff -- <編集したファイル>` で確かめる。
- transcript（`~/.claude/projects/**/*.jsonl`）を走査して使用実績を数えるときは、実行中セッション自身の transcript を除外する。
  自分が打った `grep` の引数に skill のパスが入り、「今日その skill が参照された」と誤検出した（2026-09-10）。
- skill 名の文字列一致は使用の証拠にならない（AGENTS.md の転載、skill 一覧、skill を編集したセッションに当たる）。数えるのは
  Skill dispatch（`~/.claude.json` の `skillUsage` にも残る）と、assistant の tool_use の `Read` で `file_path` が `skills/<name>/` のものだけ。
  `Edit` / `Write` は保守であって利用ではない。
- Claude Code の transcript は `cleanupPeriodDays`（既定 30 日）で消える。集計の窓は日数で報告し、薄いときは
  `skillUsage.lastUsedAt` の経過日数を併用する。Codex のログは長く残る。

## 前提にしている skill

名前で呼ぶだけで、本文は写していない。入っていなければ入れる。

- `grilling`（[mattpocock/skills](https://github.com/mattpocock/skills)、MIT）: `npx skills@latest add mattpocock/skills --skill grilling`
