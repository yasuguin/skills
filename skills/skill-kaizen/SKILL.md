---
name: skill-kaizen
description: "会話中のユーザーフィードバック、繰り返しの修正、手動フォロー、命名や workflow の違和感、反映後の不満、運用ルール変更などから、既存 skill をブラッシュアップすべきタイミングを検知して改善する。「これも skill に反映して」「今後はこうして」「毎回ここで詰まる」のような明示の依頼、`/retro` の改善候補や `/skill-doctor` の未使用 skill を直して・整理してほしいという依頼のほか、会話の流れから skill 側へ一般化すべき改善が明らかに見えたときにも使う。必要なら短くヒアリングし、対象 skill の更新、eval 見直し、変更の反映・検証・commit まで進める。"
---

# skill-kaizen

## GOAL

- 会話中のフィードバックや運用上の痛みを、その場の対応で終わらせず skill に還元する。
- どの skill をどう直すかを整理し、要るときだけユーザーに短く確かめてから直す。
- 直した内容を特定の会話に合わせすぎず、使い回せるルールに一般化する。
- 足すだけでなく、重複の統合、古くなった記述の削除、簡略化も同じ重さで検討する。
- skill の置き場の正本を直し、反映・検証・commit まで終える。

## 入口

- 会話中のフィードバック・手戻り: Workflow 1 から進める。本筋の作業の途中なら、下の「本筋と並列に回す」も見る。
- `/retro` の改善候補の一覧: 候補をそれぞれ signal として扱い、[references/retro-mapping.md](references/retro-mapping.md) で置き場所と担当の skill を振り分ける。
  skill-kaizen の担当分だけを Workflow 2 から進め、ほかの担当分はその skill 名を添えて報告する。
- `/skill-doctor`(Claude Code 組み込み。skill ごとの常駐コストと利用回数を出し、未使用の skill を挙げる)の結果: 未使用の skill を「統合・削除」の候補として
  Workflow 2 から進める。利用回数 0 だけを根拠に消さず、手動専用(`disable-model-invocation: true`)で用途が残るもの、他の skill から参照されるものは残す。
  archive の手順は repo の AGENTS.md に従う。

## PRIMARY RULES

- **まず、skill に一般化すべきかを決める**。その場かぎりの好みや一時的な事情は skill に入れない。
  逆に、毎回読むべき基本動作まで skill に逃がしていて、使うたびに skill を開かないと振る舞いが揺れるなら、AGENTS.md / CLAUDE.md へ戻す。
- **足すだけでなく、統合・削除・簡略化も毎回考える**。同じ判断基準が複数の場所にあれば、正本を 1 つに決め、ほかは参照に置き換えるか消す(決め方は Workflow 2)。
- **継ぎ足しで終わらせない**。1 行足すだけで済ませず、同じ節の既存の rule と合わせて読み直し、抽象度がそろうように節ごと書き直す。
  目の前の事例に合わせた rule を増やさず、使い回せる if/then に言い換えてから書く。ただし抽象化しすぎない(確かめ方は Workflow 4.5)。
- **ほかの skill の失敗事例を skill-kaizen 自身に積まない**。具体的な失敗の形は、その skill の evals / references に入れる。
  skill-kaizen が持つのは「改善をどう進めるか」の仕組みだけ。
- **置き場の正本を直す**。配備先のコピーだけを直さない。
- 直す対象が複数あるなら、今の会話に直接効くものから直す。
- 迷いが残るときだけ、1 回で済む粒度に絞って聞く。同じ種類の確認をユーザーに止められたら、確認を増やすのではなく、
  「どの条件なら既定で進めてよいか」を skill に書く。

## 本筋と並列に回す(Claude Code)

改善の判断には、その場の会話(ユーザーの指摘、手戻りの経緯)がそのまま要る。要約して subagent に渡すと根拠が抜け落ちる。
本筋の作業が skill の置き場の repo 以外なら、Claude Code では会話ごと fork して裏で回し、本筋は止めない。

- 呼び方: Agent tool の `subagent_type: "fork"`、`description` は `skill-kaizen: <直す内容の要約>`
  (agent-doctor がこの接頭辞で fork:skill-kaizen として数え、効果を前回と比べて追う)。prompt には
  「skill-kaizen の手順で <signal> を skill に反映する」と、対象の skill 名だけを書く。
- 本筋も skill の置き場の repo を触っているときは fork しない。同じ作業ツリーを両方が書き換えて衝突するので、本筋の区切りでその場で回す。
- fork 先はユーザーに質問できない(`AskUserQuestion` が使えない)。手順 3 のヒアリングに当たる判断と、ユーザーの承認が要る変更
  (skill の rename・archive、AGENTS.md の方針の変更)は実施せず、推奨案付きの提案として報告に返す。メインがそれを `AskUserQuestion` でユーザーに聞く。
- それ以外(skill 本体・references・evals の修正、配備先への反映、commit)は fork 先で最後まで進める。
- fork は親と同じモデル・同じ権限モードで動く。agent の側で権限を広げる手段は無いので、承認の手間を減らしたいときは
  agent ではなく settings の allow / hook を直す。

## Workflow

```
進捗チェックリスト：
- [ ] 1：改善 signal の認定
- [ ] 2：対象 skill と変更範囲の特定
- [ ] 3：必要ならヒアリング
- [ ] 4：skill 本体と補助ファイルの更新
- [ ] 4.5：整合セルフレビュー
- [ ] 5：同期と検証
- [ ] 6：commit
```

### 1. 改善 signal の認定

- goal: 会話から、skill の改善に値する signal を拾う
- rules:
  - skill の改善に値する signal か(skill にしない方がよいものか)迷うとき、明示されていない痛みを拾うときは、
    [references/trigger-signals.md](references/trigger-signals.md) の例と照らす
  - 拾った signal は「明示依頼」「反復 pain」「仕様ずれ」「完了条件ずれ」のどれかに分類する
  - 期待どおりに止まれた事例も signal になる。範囲を広げずに止まれた、差分が 0% だと気づいて終えられた、が評価されたら、使い回せる停止条件として書けるかを考える
  - ユーザーが「そこは毎回聞かなくてよい」のように確認を止めたら、`反復 pain` として扱う
  - ユーザーが既存の手編集の差分を比べる材料にしたいと言ったら、signal を認める前に、その差分を単独の commit か明示の diff に固定する
  - その会話だけの一時的な事情なら skill にしない

### 2. 対象 skill と変更範囲の特定

- goal: どの skill のどこを直すかを決める
- rules:
  - 既存の skill の一覧から、いちばん近い skill を 1 つか少数に絞る
  - 新しい skill を作る形に見えても、まず同じ prefix・同じ対象領域の既存の skill が無いかを確かめる。既存の skill の `references/` にファイルを足す、
    SKILL.md に 1 節足す、で賄えるなら新しく作らない。新しく作る条件と迷ったときの確かめ方は `skill-creator` の「本当に新規 skill が要るか」節に従う
  - 問題が「skill 側に足りない」のか「instruction file から逃がしすぎた」のかを先に切り分ける
  - **正本を決める**(この節が正本)。対象の skill 本体、関連する他の skill、AGENTS.md / CLAUDE.md、hooks を横断して検索し、同じ判断基準や注意書きが
    複数の場所にないかを確かめる。あれば、スコープと詳細度で正本を 1 つ決める(全プロジェクト共通で高頻度な一般則は AGENTS.md / CLAUDE.md、
    詳しい判断基準や手順は該当の skill、機械で検知できるものは hook)。正本以外は参照 1 行に縮めるか消す。
    「AGENTS.md / hook がいつも優先」のような固定の順番ではなく、そのつどスコープで決める
  - 直す場所を次から選ぶ。全部を機械的に触らない
    - frontmatter(description): trigger の漏れや誤発火があるとき
    - GOAL / PRIMARY RULES: 完了条件や必須の動作が足りないとき
    - workflow: 順序や承認のゲートが抜けていたとき、不要な確認が多く既定で進めてよい条件を書くべきとき、
      見た目の成功だけでなく実際の約束が果たされたかを確かめる手順が要るとき
    - references: 長い判断基準や対応表が要るとき
    - scripts: 再利用しやすい処理を切り出すとき
    - evals: 同じ失敗を繰り返させたくないとき、実害のあった見逃しを再現の prompt として固定したいとき、よい粒度の成功の形を既定にしたいとき
    - instruction file へ戻す: skill に寄せすぎて、日常の振る舞いまで外に逃げたとき
    - 統合・削除: 同じ判断基準が複数の場所に重複しているとき、加筆を重ねて今のベストプラクティスと食い違う記述や使われなくなった記述が残っているとき
  - 複数の場所を触るときも、それぞれ「なぜその変更が要るか」を一言で言える状態にする
  - **skill の rename** を含むときは、旧名の alias を作らない。旧名を参照している skill、eval、settings、catalog、README、script、reference を検索し、
    同じ作業の中で新しい名前へ移す。命名規則の正本は、利用者の skill の置き場の README などにあるので、それに従う
  - 手編集の差分を根拠に直すなら、証拠の commit と skill の修正の commit を分ける

### 3. 必要ならヒアリング

- goal: 勝手な一般化を避ける
- rules:
  - 次の場合だけ聞く
    - どの skill を直すべきか曖昧
    - 方針が 2 通り以上あり、どちらを既定にするかで振る舞いが変わる
    - 今回だけの好みか、今後の既定のルールかが分からない
  - 質問は短く、決めるのに要る論点だけにする
  - 例:
    - 「これは今回だけでなく、今後の既定の動作にしますか」
    - 「rename を今回の作業に含めますか、別の作業に分けますか」

### 4. skill 本体と補助ファイルの更新

- goal: 改善の内容を skill に落とし込む
- rules:
  - 足す前に、本当に AGENTS.md / CLAUDE.md ではなく skill に置くべきかを確かめる
  - 文書の書き方(何を書き、何を削るか)は `writing-for-agents` に従う
  - 文書に Python を実行する検証・補助のコマンドを書くときは、ユーザーや repo の指示が無い限り `uv run --no-project python ...` で書く
    (`python3 ...` を既定の例にしない)
  - SKILL.md の本文は 500 行以内を目安にし、超えるなら `references/` に分ける。ただし外部の skill(hono など)は、upstream に追従しやすいよう分けない
  - 実害のある見逃しや手戻りを一般化するときは、対象の skill の evals と references に入れる(skill-kaizen 自身ではなく、該当の skill に積む)
  - eval の形式は目的で選ぶ。2 つの形式は互換ではないが、併存してよい
    - skill を作る・大きく作り直すときに、出力を人が見比べて良し悪しを決めるなら `evals/evals.json`(`skill-creator` の形式とループ)
    - 直した振る舞いが戻らないかを機械の判定で繰り返し確かめたいなら、公式の形式の `evals/<case>/prompt.md` + `graders/*.md`(`claude plugin eval`)。
      振る舞いを直すときは、直す前に落ちる case を先に足すと、直した効果を示せる
    - 既存の `evals.json` を公式の形式へ一括で移さない。公式の形式の置き場所の設定は `experimental` の下にあり仕様が動きうるので、公式の形式を足すのは回帰を見張りたい skill に限る
    - 文言だけの修正では、どちらの eval も足さない
    - 根拠: 公式ドキュメントは移行を求めておらず、互換性が無いとだけ書いている(https://code.claude.com/docs/en/plugin-evals.md)
  - ユーザーが望んだ「よい粒度」の進め方がはっきりしたら、その成功の形も対象の skill の rule と eval に入れる
  - 「完了を早く言いすぎた」「100% の前に止めた」種類の失敗では、対象の skill の停止条件と完了条件の両方を書く

### 4.5. 整合セルフレビュー

- goal: 「書いた直後の自分」ではなく「初めて読む利用者」として、編集した skill の全体を読み直す
- rules:
  - 編集した節だけでなく、その skill の SKILL.md・references・scripts・evals を通して読み直す。1 行の追記でも、リファクタでも省かない。
    実装の変更を伴う改善ほど、説明文が置き去りになりやすい
  - 次の 4 点を確かめ、1 つでも落ちていれば 4 に戻る
    1. **実装・eval との一致**: scripts / hooks の挙動を説明している文が、今のコードと合っているか。引数、判定の方法、出力の文言、タイムアウトの値に加え、
       「誰が何をするか」(出力の書式を組み立てるのは script か、エージェントか)まで照らす。`evals/` の期待値や grader に、古い仕様・古い書式が残っていないかも見る。
       script を変えたら、その script に触れる文をすべて grep して照らす。古い実装の説明が残るのが、いちばん見つけにくいミス
    2. **具体例がある**: 抽象化した rule ごとに、利用者が判断に使える具体例が少なくとも 1 つ残っているか
       (どのツール・どのコマンド・どの出力を見れば条件を満たすと分かるか)。例が無い rule は読んでも動けないので、事例の列挙ではなく判断の手がかりとして 1 つ戻す
    3. **分岐を落としていない**: 手順にフォールバック・例外・別の経路(script が使えない場合、ホストが機能を持たない場合、並行の実行が重なる場合など)があるなら、
       その分岐でも報告や完了条件がどうなるかが書かれているか
    4. **構造が崩れていない**: 加筆を重ねた skill に起きやすい次の形が無いか。あれば節の組み立てから直す
       - 用途や入口が複数あるのに、冒頭に振り分けが無い
       - 毎回やる必須の手順が、Gotchas や注意書きの節に埋もれている
       - PRIMARY RULES がふくらみ、特定の手順の細部や script の中の動き(待ち時間、内部のフラグなど)まで入っている
       - 同じ規則が、同じファイルの中でも複数の場所(PRIMARY RULES・Workflow・注意書き)に書かれている
  - 一般化した rule には、元になった事例を当てはめ、防ぎたかった失敗が防げるか(なぜそう決めたか、どの固有のケースを防ぐかが復元できるか)を確かめる。
    復元できない一般則は本質を落としているので、条件・境界・例外を 1 つ戻す。固有のケースは本文から消すのではなく、置き場所を分ける
    (判断基準は SKILL.md の本文、具体例と経緯は references / evals、script の挙動の根拠は script の why コメント)

### 5. 同期と検証

- goal: 直した skill を実際に使える状態にする
- rules:
  - frontmatter を更新したら、YAML として読めることを確かめる
  - 見出し・決まった言い回し・マーカーの文字列を書き換えたら、scripts / hooks / evals がその文字列を照合していないかを grep で確かめる。
    書き換えの前と後で、コードブロックとインラインコードを抜き出して比べると、意図しない変更を機械で見つけられる
  - Python の script を足した・直したら `uv run --no-project python -m py_compile <file...>` を実行する
  - `git diff --check` を実行する
  - 配備先へ反映する仕組みがあるなら、差分を確かめて要る path だけを反映し、反映後に配備先を確かめ直す

### 6. commit

- goal: 改善を履歴に残す
- rules:
  - ユーザーの手編集の差分を証拠として固定した commit があるなら、そのあとの skill の改善の commit と分けたまま扱う
  - 変更の単位ごとに日本語で commit する
  - 何を signal として拾い、何を一般化したかを、最終報告で短く説明する

## 前提にしている skill

名前で呼ぶだけで、本文は写していない。入っていなければ入れる。

- `writing-for-agents`・`domain-modeling`・`retro`([mattpocock/skills](https://github.com/mattpocock/skills)、MIT): `npx skills@latest add mattpocock/skills --skill writing-for-agents --skill domain-modeling --skill retro`
- `skill-creator`([anthropics/skills](https://github.com/anthropics/skills)): `npx skills@latest add anthropics/skills --skill skill-creator`
