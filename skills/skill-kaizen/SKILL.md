---
name: skill-kaizen
description: "会話中のユーザーフィードバック、繰り返しの修正、手動フォロー、命名や workflow の違和感、反映後の不満、運用ルール変更などから、既存 skill をブラッシュアップすべきタイミングを検知して改善する。ユーザーが「これも skill に反映して」「今後はこうして」「毎回ここで詰まる」などと言ったときや、`/retro` の改善候補や `/skill-doctor` の未使用 skill を直して・整理してほしいと言ったときだけでなく、会話の流れから明らかに skill 側へ一般化すべき改善が見えた場合にも使用する。必要なら短くヒアリングし、対象 skill の更新、eval 見直し、変更の反映・検証・commit まで進める。"
---

# skill-kaizen

## GOAL

- 会話中のフィードバックや運用上の痛みを、場当たり対応で終わらせず skill に還元する。
- どの skill をどう直すべきかを整理し、必要ならユーザーに短く確認してから改善する。
- 修正内容を特定の会話だけに過剰適合させず、再利用可能なルールへ一般化する。
- 改善は加筆だけでなく、重複記述の統合・非ベストプラクティスな記述の削除・簡略化も対等な選択肢として扱う。
- skill の置き場の正本を直し、変更を反映・検証し、commit まで完了させる。

## PRIMARY RULES

- まず「これは skill 修正に一般化すべきか」を判断する。単発の好みや一時的事情は無理に skill へ入れない。
- skill へ逃がしすぎていないかも同時に見る。高頻度の判断基準、日常の振る舞いを矯正するルール、エージェントの根幹動作は instruction file 側に残す候補として扱う。
- 改善依頼を受けたら、対象 skill 単体で完結させず、関連する AGENTS.md / CLAUDE.md、他 skill、hooks を横断的に確認する。同じ判断基準が複数箇所に重複していれば、正本を 1 つ決めて他は参照に置き換えるか削除する。「どこに足すか」だけでなく「どこを削れるか」も毎回検討する。
- 次の signal が 1 つでも強ければ、skill 改善候補として扱う。
  - ユーザーが明示的に「skill に反映して」「今後はそうして」と言う
  - ユーザーが「いったんコミットしてから比較して skill を直して」と言う
  - 同じ補足説明、同じ確認、同じ手戻りが 2 回以上出る
  - 既存 skill が under-spec で、会話中に実運用ルールが後から追加された
  - skill の description、GOAL、workflow、完了条件が実際の期待とずれていた
  - 反映後や納品後に「そこまでやってほしかった」と scope の穴が見えた
  - ユーザーが、より厳しい粒度のやり切り方を明示的に評価し「今後は毎回この粒度で」と言った
  - 逆に、対象を広げずに差分 0% を認識して止まれたことが明示的に評価され、その停止条件が再利用可能だと分かる
  - 具体的な signal パターンの一覧は [references/trigger-signals.md](references/trigger-signals.md) を参照する
- 逆に、skill 化した結果「毎回読むべきルールが本文から消えた」「使うたびに skill を開かないと基本動作が揺れる」なら、skill 側ではなく AGENTS.md / CLAUDE.md へ戻す改善候補として扱う。
- 改善対象が複数ある場合は、今の会話に直接効くものを先に直す。
- 迷いが残るなら短くヒアリングする。質問は 1 回で済む粒度に絞る。
- 同じ種類の過剰確認をユーザーに止められた場合は、確認回数を増やすのではなく「どの条件なら既定で進めてよいか」を skill 側へ一般化する。
- skill 名、description、workflow、references、evals のどこを直すべきかを分けて考える。全部を機械的に触らない。
- skill 名を変更する場合は旧名 alias を新規作成しない。旧名を参照している skill、eval、settings、catalog、README、script、reference を検索し、その rename と同じ作業単位で新名へ移行する。
- 命名規則の正本は、利用者の skill 置き場の README などにある。rename や新名の判断はそこに従う。
- SKILL.md 本文は 500 行以内を目安にし、超える場合は references/ へ分割する。ただし外部 skill（hono 等）は upstream 追従性を優先して分割しない。
- 継ぎ足しで終わらせない。既存の記述に 1 行足すだけで済ませず、同じ節の既存 rule と合わせて読み直し、
  抽象度が揃うように節ごと書き直す。目の前の事例だけに合わせた rules を増やさず、抽象化できる if/then に
  言い換えてから書く。
- 抽象化しすぎない。一般則に言い換えたあと、元の事例をその一般則に当てはめて「なぜそう決めたか」と
  「どの固有ケースを防ぐか」が復元できるか確認する。復元できない一般則は本質を落としているので、
  条件・境界・例外を 1 つ戻す。固有ケースは本文から消すのではなく、置き場所を分ける
  (判断基準は SKILL.md 本文、具体例と経緯は references / evals、script の挙動の根拠は script の why コメント)。
- 他 skill 固有の失敗事例を skill-kaizen 自身の PRIMARY RULES やステップに積まない。具体的な失敗パターンは該当 skill の evals / references に反映する。skill-kaizen が持つのは「改善をどう進めるか」の仕組みだけ。
- 既存 skill は、配備先のコピーではなく置き場の正本側を編集する。ローカルだけ直さない。
- Python を実行する検証・補助コマンドは、ユーザーや repo 指示で別指定がない限り `uv run --no-project python ...` で書く。`python3 ...` を既定例にしない。

## 本筋と並列に回す（Claude Code）

改善の判断にはその場の会話（ユーザーの指摘、手戻りの経緯）が要るので、要約して渡すと根拠が痩せる。
本筋の作業が skill の置き場の repo 以外なら、Claude Code では会話ごと fork して裏で回し、本筋は止めない。

- 呼び方: Agent tool の `subagent_type: "fork"`、`description` は `skill-kaizen: <直す内容の要約>`
  （agent-doctor がこの接頭辞で fork:skill-kaizen として数え、効果を前回比で追う）。prompt には
  「skill-kaizen の手順で <signal> を skill に反映する」と、対象の skill 名だけを書く。
- 本筋も skill の置き場の repo を触っているときは fork しない。同じ作業ツリーを
  両方が書き換えて衝突するため、本筋の区切りでその場で回す。
- fork 先はユーザーに質問できない（`AskUserQuestion` が使えない）。手順 3 のヒアリングに当たる判断と、
  ユーザーの承認が要る変更（skill の rename・archive、AGENTS.md の方針変更）は実施せず、推奨案付きの提案として
  報告に返す。メインがそれを `AskUserQuestion` でユーザーに聞く。
- それ以外（skill 本体・references・evals の修正、配備先への反映、commit）は fork 先で最後まで進める。
- fork は親と同じモデル・同じ権限モードで動く。agent 側で権限を広げる手段は無いので、承認の手間を減らしたいときは
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

- goal: 会話から skill 改善に値する signal を拾う
- rules:
  - まず [references/trigger-signals.md](references/trigger-signals.md) を読む
  - signal を「明示依頼」「反復 pain」「仕様ずれ」「完了条件ずれ」のどれかに分類する
  - ユーザーが既存の手編集差分を比較材料にしたいと言った場合は、signal 認定の前提として差分を単独コミットまたは明示 diff に固定する
  - ユーザーが「そこは毎回聞かなくてよい」「それは rename-only で進めてよい」のように、過剰確認を明示的に止めた場合は `反復 pain` または `workflow の過剰確認` として扱う
  - 期待どおりに止まれた事例も signal として扱う。特に `scope を勝手に広げない`, `差分 0% を認識して終了する` が評価された場合は、再利用可能な停止条件として抽象化できるか検討する
  - その会話だけの一時事情なら skill 化しない
  - `/retro` の候補一覧を渡されたら、それぞれを signal として扱い、[references/retro-mapping.md](references/retro-mapping.md) で置き場所と担当 skill を振り分ける。skill-kaizen の担当分だけを 2 以降で直し、他の担当分はその skill 名を添えて報告する
  - `/skill-doctor`（Claude Code 組み込み。skill ごとの常駐コストと利用回数を出し、未使用 skill を挙げる）の結果を渡されたら、未使用 skill を「統合・削除」の候補として扱う。利用回数 0 だけを根拠に消さず、手動専用（`disable-model-invocation: true`）で用途が残るもの、他 skill から参照されるものは残す。archive の手順は repo の AGENTS.md に従う

### 2. 対象 skill と変更範囲の特定

- goal: どの skill のどこを直すか決める
- rules:
  - 既存 skill 一覧から最も近い skill を 1 つまたは少数に絞る
  - 改善案が「新規 skill を作る」形に見えても、まず同じ prefix・同じ対象領域の既存 skill が無いか確認する。
    既存 skill の `references/` へ追加ファイルを足す・SKILL.md へ 1 節足すだけで賄えるなら、新規 skill を
    作らずそちらで済ませる。新規作成が要る条件・迷ったときの確認方法は `skill-creator` の「本当に新規
    skill が要るか」節に従う
  - 手編集差分を根拠に改善するなら、skill 修正と同じコミットへ混ぜず、証拠コミットと skill 修正コミットを分ける
  - skill rename を含む場合は、互換 alias ではなく全参照移行を変更範囲に含める
  - 問題が「skill 側に足りない」のか「instruction file から逃がしすぎ」のかを先に切り分ける
  - 対象 skill 本体・関連する他 skill・AGENTS.md/CLAUDE.md・hooks を横断検索し、同じ判断基準や同じ注意書きが
    複数箇所に重複していないかを確認する。重複があれば、スコープと詳細度で正本を 1 つ決める
    （全プロジェクト共通かつ高頻度な一般則は AGENTS.md/CLAUDE.md、詳細な判断基準や手順は該当 skill、
    機械的に検知できるものは hook）。正本以外は参照 1 行へ縮約するか削除する。どちらを正本にするかは
    「AGENTS.md/hook が常に優先」のような固定順ではなく、都度スコープで判断する
  - 修正対象を次から選ぶ
    - frontmatter
    - GOAL / PRIMARY RULES
    - workflow
    - references
    - scripts
    - evals
    - instruction file へ戻す
    - 統合・削除（重複記述の一本化、非ベストプラクティスになった記述や使われなくなった記述の削除）
  - 同時に複数箇所を触る場合も、「なぜその変更が必要か」を一言で説明できる状態にする

### 3. 必要ならヒアリング

- goal: 勝手な一般化を避ける
- rules:
  - 次の場合だけヒアリングする
    - どの skill を直すべきか曖昧
    - 2 通り以上の方針があり、どちらを既定にするかで挙動が変わる
    - 単なる今回だけの好みか、今後の既定ルールかが不明
  - 質問は短く、決定に必要な論点だけ聞く
  - 例:
    - 「これは今回だけでなく、今後の既定動作にしますか」
    - 「rename を今回の作業に含めるか、別の作業に分けるか」

### 4. skill 本体と補助ファイルの更新

- goal: 改善内容を skill に落とし込む
- rules:
  - skill へ追加する前に、本当に AGENTS.md / CLAUDE.md ではなく skill に置くべきかを確認する
  - 文書としての書き方（何を書き、何を削るか）は `writing-for-agents` に従う
  - workflow 変更なら `SKILL.md` 本体を直す
  - 判断材料が長くなるなら `references/` に逃がす
  - 実害のある見逃しや手戻りを一般化するときは、対象 skill の evals と references に反映する（skill-kaizen 自身ではなく、該当 skill に積む）
  - eval の形式はケースバイケースで選ぶ。どちらかがベストプラクティスというわけではなく、公式ドキュメントも移行を求めていない（互換性が無いとだけ書いている。https://code.claude.com/docs/en/plugin-evals.md ）
    - skill を作る・大きく作り直すときに、出力を人が見比べて良し悪しを決めるなら `evals/evals.json`（`skill-creator` の形式とループ）
    - 直した振る舞いが戻らないかを機械判定で繰り返し確かめたいなら、公式形式の `evals/<case>/prompt.md` + `graders/*.md`（`claude plugin eval`）。振る舞いを直すときは、修正前に落ちる case を先に足すと修正の効果を示せる。
    - 両形式の併存はよい。既存の `evals.json` を一括で公式形式へ移さない。公式形式の置き場所設定は `experimental` 配下で仕様が動きうるため、公式形式を足すのは回帰を見張りたい skill に限る
    - 文言だけの修正では、どちらの eval も足さない
  - ユーザーが望んだ「よい粒度」の進め方が明確なときは、その成功パターンも対象 skill の rule と eval に昇格させる
  - 「完了を早く言いすぎた」「100% 前に止めた」種類の失敗では、対象 skill の停止条件と完了条件の両方を明文化する
  - script 化したほうが再利用しやすい処理は `scripts/` に分離する

### 4.5. 整合セルフレビュー

- goal: 「書いた直後の自分」ではなく「初めて読む利用者」として、編集した skill 全体を読み直す
- rules:
  - 編集した節だけでなく、その skill の SKILL.md・references・scripts・evals を通しで読み直す。
    1 行の追記でもこの通し読みを省かない
  - 次の 3 点を機械的に確認し、1 つでも落ちていれば 4 に戻る
    1. **実装との一致**: scripts / hooks の挙動(引数、判定方法、出力文言、タイムアウト値)を説明している
       文が、現在のコードと一致しているか。script を変えたら、その script に言及する全文を grep して
       照合する。旧実装の説明が残るのが最も見つけにくいミス
    2. **具体例の存在**: 抽象化した rule ごとに、利用者が判断に使える具体例が最低 1 つ残っているか
       (どのツール・どのコマンド・どの出力を見れば条件を満たすと分かるか)。例が無い rule は
       「読んでも動けない」ので、事例列挙ではなく判断の手掛かりとして 1 つ戻す
    3. **分岐の網羅**: 手順にフォールバック・例外・代替経路(script が使えない場合、ホストが機能を
       持たない場合、並行実行が重なる場合など)があるなら、その分岐でも報告や完了条件がどうなるかが
       書かれているか。主経路だけ書いて分岐を落としていないか
  - 一般化した rule は、元になった事例をその rule に当てはめて、防ぎたかった失敗が防げるか
    (復元できるか)を確かめる。復元できなければ PRIMARY RULES「抽象化しすぎない」に従い条件を戻す
  - 「今回はリファクタだから」「追記が小さいから」を理由にこの節を飛ばさない。実装変更を伴う改善ほど
    説明文が置き去りになりやすい

### 5. 同期と検証

- goal: 修正した skill が実際に使える状態にする
- rules:
  - frontmatter を更新したら YAML として読めることを確認する
  - Python script を追加・更新したら `uv run --no-project python -m py_compile <file...>` を実行する
  - `git diff --check` を実行する
  - 配備先へ反映する仕組みがあるなら、差分を確かめて必要な path だけ反映し、反映後に配備先を再確認する

### 6. commit

- goal: 改善を履歴に残す
- rules:
  - ユーザーの手編集差分を証拠として固定したコミットがある場合は、その後の skill 改善コミットと分離したまま扱う
  - 変更単位ごとに日本語コミットを作る
  - 何を signal として拾い、何を一般化したかを最終報告で短く説明する

## When To Read References

- どの signal を skill 改善扱いにすべきか迷ったら [references/trigger-signals.md](references/trigger-signals.md)
- 配備先への反映の流れが必要なら、その repo の手順に従う
- `/retro` の候補を受けて直すときは [references/retro-mapping.md](references/retro-mapping.md)

## 前提にしている skill

名前で呼ぶだけで、本文は写していない。入っていなければ入れる。

- `writing-for-agents`・`domain-modeling`・`retro`（[mattpocock/skills](https://github.com/mattpocock/skills)、MIT）: `npx skills@latest add mattpocock/skills --skill writing-for-agents --skill domain-modeling --skill retro`
- `skill-creator`（[anthropics/skills](https://github.com/anthropics/skills)）: `npx skills@latest add anthropics/skills --skill skill-creator`
