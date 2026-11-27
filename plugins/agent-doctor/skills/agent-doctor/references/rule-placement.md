# ルールの最適化（prose から機械的な強制へ）

方針は SKILL.md の「ルールの直し方の方針」。prose のルールは読み飛ばされ、常時 prompt に載る分だけコンテキストを
食い、さらに実際の強制とずれていても誰も気づかない（2026-10-13 の精査では「npm は hook が block」と
書いてあるのに Codex では allow、「bare python は block 済み」と書いてあるのにどこでも未強制だった）。

この精査は、文章に残った決まりと、強制とのずれをまとめて棚卸しするためのもの。決まりを書いたその場で
機械化を促す hook（指示ファイル・skill に決まりを文章で足したら一言添える PostToolUse hook）があると、棚卸しの量が減る。

## 目次

- 読む面と強制の所在
- 分類
- 移す先の選び方
- 手順
- 各 repo の AGENTS.md
- 落とし穴

## 読む面と強制の所在

常時 prompt に載る面を先に読む。読者が誰かで、削ってよい条件が変わる。

- 全 repo 共通の instruction file（`~/.claude/CLAUDE.md`、Codex の `~/.codex/AGENTS.md` など）: それを読むすべての agent。
  Claude と Codex が同じファイルを共有していれば両方。
- Claude だけが読む面: `~/.claude/rules/*`、`~/.claude/agents/*` の本文。
- 各 repo の `AGENTS.md` / `CLAUDE.md`: その repo で動く全 agent。
- Claude Code の settings の `autoMode`（allow / soft_deny / environment）: Claude の auto mode の classifier。
- skill の guard モード節（「〜を新規導入しない」と自動 trigger で止める節）: その skill を読んだ agent。

強制の所在:

- Claude: settings の `permissions`（allow / ask / deny）、hook（PreToolUse・PostToolUse・Stop など）、
  agent 定義の frontmatter（`disallowedTools`）
- Codex: `~/.codex/rules/*.rules`（`prefix_rule`）、`hooks.json`（ライフサイクル処理と、prefix で判定できない Bash の検査）、
  profile の設定
- 共通: git hook（`.githooks/`・`.husky/`・lefthook）、lint、test、CI

強制の仕組み同士が噛み合っているかも見る。hook・skill・Stop hook が案内するコマンドが、permissions・
hook・sandbox の下で実際に通るかを確かめる。速度の診断（`scripts/analyze.py`）の
「ガードに止められた回数」に、同じ理由の hook の拒否・classifier の拒否が並んでいたら、
その経路が手がかりになる。

## 分類

各ルールを次のどれかに分ける。判定の軸は「正規表現や単純なパーサだけで、周辺の意味を読まずに yes/no を
決められるか」。

- **C. 書いてあることと強制がずれている、または仕組み同士が矛盾している** — 最優先。例:
  - 共有の AGENTS.md に「hook が block」とあるが、Codex には同じ強制が無い。autoMode の prose が、存在しない
    hook を根拠にしている。
  - 仕組み同士の矛盾で、正規の経路が無くなっている。hook が「git push は単独で呼べ」と強制する一方、
    作業ディレクトリの外へ cd すると cwd がリセットされ、別 repo へ push する手段が無くなっていた。
    Stop hook が唯一の正規手段として案内する `--ack` が、sandbox の allowWrite に state のディレクトリが無く
    失敗していた。
  - hook の誤検出で、正当なコマンドが止まる。説明として書いた commit メッセージや grep の検索語に禁止語が
    含まれるだけで止まっていた。
- **A. 機械的に判定できるのに prose だけ** — 特定コマンド名の禁止・置き換え（npm → pnpm）、特定の文字種・
  文字列（絵文字、日本語でない commit メッセージ）、特定パスへの書き込み、固定フォーマット、特定 agent に
  使わせないツール。
- **B. 強制済みなのに prose にも書いてある** — 削るか、誘導 1 行に縮める。
- **E. harness 自体が保証している** — 削る（例: Edit ツールは事前の Read を要求する）。
- **D. 判断が要る** — prose のまま残す。設計判断（原因を調べてから直す）、意図確認、TDD の順序のように
  意味や時系列の理解が要るもの。迷ったら D にし、保留の理由を報告に書く。


## 移す先の選び方

ルールの形ごとの移す先。

- **Claude のコマンドの許可・確認・禁止で、先頭の引数で決まる**: `permissions` の allow / ask / deny。
- **コマンド文字列の中の禁止パターン、ファイルに書き込む内容の禁止パターン**: PreToolUse hook。パターンを
  データ（JSON など）に分けた registry にすると、足すたびに hook を書かずに済む（`ban-rule-manager` skill）。
- **registry の型に収まらない検査**（commit メッセージの言語、最終回答の書式など）: 既存の hook の規約に合わせて追記
  （`hook-conventions.md`）。最終回答の検査は Stop hook。
- **特定 agent に使わせないツール**: agent 定義の `disallowedTools`（`claude --agent <name>` の main session にも効く）。
  advisor のようなサーバー側のツールは消えない（足しても `claude --agent worker -p` で残った。2026-11-26 実測）ので D に残す。
- **特定 agent の Bash での書き換え・commit・push**（「読み取り専用」「commit しない」）: hook の入力の `agent_type` で止める。
  `disallowedTools` の Edit・Write だけでは Bash の `git commit`・`sed -i` で抜ける。定義の文言と hook の対象はテストで突き合わせる。
- **Codex の特定 profile（worker など）だけの禁止**: profile の `shell_environment_policy.set`。rules と hook は全体共通で
  profile ごとに分けられない。例: git の設定を環境変数で渡し、push 先を `pushInsteadOf` で存在しない転送方法に書き換えて
  push を失敗させる。
- **repo の中の設定・workflow の形のずれ**（テスト・CI の方針など）: 定期の点検、手で確かめる CLI、書いた直後の
  PostToolUse hook の 3 つで同じ判定関数を使う。
- **方針を変えた後の古い言い回し**: 古い言い回しと今の言い方の対応表を持つテストを置き、repo 全体を grep させる。
  skill を写して作ると、古い方針の文も写る。
- **判定が誤りうる、または正当な例外がある**（コメントの言語、CI の待ち）: 止めずに hook の `additionalContext` で一言添える。
- **Codex のコマンドの許可・確認・禁止**: rules の `prefix_rule`（`forbidden > prompt > allow`）。PreToolUse hook にしない。
- **どれでも書けない、classifier への文脈**: `autoMode`（最後の手段）。

移す先ごとの注意:

- `permissions` は前方一致。`git push origin main --force` のような後置のフラグは deny の前方一致で拾えないので、
  危険な形を含みうるコマンドは引数を固定した allow にするか、hook のパターンで止める。
- auto mode では、狭い allow ルールは classifier より先に判定されて確実に通る。`Bash(*)` やインタプリタの
  ワイルドカードのような包括的な allow は捨てられる。
- `autoMode.environment` には信頼する組織・repo・ドメインだけを書き、`"$defaults"` を必ず入れる。外すと既定の
  Trusted repo（作業ディレクトリとその remote）まで消える。特定 project の deploy 先や bucket は全 repo に効く
  ユーザー設定に書かない（project の `.claude/settings.json` の `autoMode` は読まれない）。
- Claude と Codex の両方に同じ hook を実装しない。Codex 側の判断と出力契約（`ask` は hook failed になる）は
  `hook-conventions.md`。

## 手順

1. **棚卸しする。** 上の面を読み、ルールごとに強制の有無を grep で確かめる。量が多ければ Explore agent に
   分類させてよいが、「強制済み」を根拠に prose を消す項目と、C の項目は自分で grep して裏を取る。
2. **報告して選んでもらう。** 分類ごとに `ファイル:行`、原文の短い引用、根拠（どこが強制しているか、または
   どう機械化できるか）を付ける。C を先頭に置き、一度に全部は実装しない。
   agent 自身の権限・hook・sandbox を広げる変更（allow ルール、excludedCommands、autoMode の allow）は、
   足す項目そのもの（例: `Bash(git commit *)` を allow に足す）を選択肢に書いて選んでもらう。auto mode の
   classifier は、ユーザーがその変更を具体的に指名していない自己設定の変更を Self-Modification として止める。
   「承認なしで通るようにしたい」のような方針の依頼だけでは足りない。
3. **実装する。** Claude Code・Codex の hook、registry、Codex rules、profile の振る舞いを変えるなら、失敗するテストを先に書く。
   正規表現は「表面上似ているが許可すべきケース」を最低 1 つテストに入れる。特に引用符の中、heredoc の本文、
   grep の引数、commit メッセージ（禁止語を説明として書いただけで止まりやすい）。
4. **prose を縮める。**
   - Claude と Codex の両方が読む面は、すべての読者で強制済みのものだけルールごと削る。Claude でしか強制して
     いないものはルールの本文を残し、「Claude Code では hook が block」のような強制の所在の注記は付けない
     （止められたときに hook が理由を返すので、注記はどの読者の行動も変えず、設定を変えたときに古くなる）。
     例: 絵文字の禁止は Claude の hook だけなので、共有 skill の「絵文字は使わない」は残す。`git push --force` は
     Codex の `default.rules` でも forbidden なので、「force push は hook が止める」は消す。
   - Claude 専用の面は、Claude で強制済みなら削る。止められた後の正しい手順（例: force push はユーザーに `!` で
     頼む）だけは手順として残す。
   - 理由（why）が script の docstring や設定の近接コメントに残っていることを確かめてから prose を消す。
     残っていなければ先にそちらへ移す。
   - 移行元が skill の guard モードなら、guard の記述は消さず「新規導入は hook が防ぐ。この skill は既存の
     除去に専念する」と役割分担を書く。guard モードの自動 trigger を止めるかはユーザーに聞く。
5. **確かめて反映する。**
   - Claude の hook・registry: 対象の hook のテスト。block されるべき入力と、許可されるべき入力の両方を確かめる。
   - Codex rules: `codex execpolicy check --rules <file> <コマンドのトークン...>` で変更前後の判定を比べる。

6. **事例を残す。** 移す先や誤検出の対策で判断したことを、`rule-placement-examples.md` の型で記録先に 1 件足す。
   次に同じ迷い方をしたときに読む。

## 各 repo の AGENTS.md

repo の `AGENTS.md` には、その repo で動く全 agent の毎リクエストに載る。書いた分だけ全コールに上乗せされる。

- 全体の instruction file（全 repo 共通の AGENTS.md など）で分かることは書かない（TDD、hook の方針、サブエージェント、ツールの既定など）。
  無ければ `# AGENTS` の 1 行だけで作り、repo 固有の事実（コマンド名と所要時間、hook の中身、デプロイ経路、所有境界、凍結事項、
  環境の罠）は推測で書かず、要るようになった時点で 1 行ずつ足す。
- `@` import を使わない。参照ではなく全文の読み込みになる（実測: ある repo は本体 2,721 tok に対し import が
  4,759 tok で、実効サイズの 64% だった）。参照させたいだけなら `` `README.md` `` のようにパスを書く。
- 予算は 3,000 tok（import 展開後）を目安にする。超えたら削らずに移す先を決める。
  - 機械で判定できる禁止 → 上の「移す先の選び方」
  - 手順・チェックリスト → その repo の skill（`.agents/skills/` に置き、`.claude/skills`・`.codex/skills` から symlink で指す）
  - 仕様・背景 → `README.md` / `docs/`
  - コードから戻せない判断の根拠 → コードの近くのコメント。覆しにくく、トレードオフがあったものだけ `docs/adr/`
  - 用語 → `GLOSSARY.md`、見た目の規約 → `DESIGN.md`
- 決定の履歴（「（2026-09-04 ユーザー決定）」の見出しなど）を溜めない。今有効なルールだけを書き、経緯は git log と ADR に残す。
- hook や CI が強制するコマンドを「commit 前に実行する」と書かない。agent は強制に気づかず両方回す（1 app の変更で
  モノレポ全体の typecheck を毎回回す、hook が強制する format を先回りで回す、を実測した）。書くのは hook の対象外の
  検証の task 名・対象範囲・所要時間の事実だけ（例: `pnpm test` 全件約 80 秒、部分は `pnpm test:affected`）。

検証ゲートの置き場所:

- 最終ゲートは CI。format・lint・静的な設定検証など、副作用が無く数秒で終わるものから CI に載せる。
- commit 時の hook は、staged だけを対象に即座に終わり、かつ commit で止めないと手戻りが大きい検査（生成物の先祖返り、
  配布物の構文崩れ）だけにする。遅い検査を置くと対話が止まる（191〜208 秒の test suite を pre-commit に置いた repo で、
  commit ごとに 3 分半待った）。

## 落とし穴

- 禁止パターンを引用符の外に書いたコマンド（`codex execpolicy check` に渡すトークンなど）は、自分の hook に
  止められる。判定したいコマンドは一時ファイルに書いて読ませる。引用符の中と heredoc の本文は、hook が照合の
  前に除く（`strip-shell-literals.pl`）ので止まらない。
- zsh では `$var` が単語分割されない。`codex execpolicy check` にトークンを渡すときは `${=var}` と書く。
  `while read` のループの中では、`codex` が stdin を読んでループの入力を食うので `</dev/null` を付ける。
- 新しい settings・hook が効くのは新しいセッションから。同じセッションでの「通った・止まった」は、
  直前のユーザー発言が classifier に明示の意図として読まれた結果のこともあり、ルールが効いた証拠にならない。
  agent 定義や profile を変えたら、新しいプロセスで確かめる（`claude --agent <name> -p "…"`、`codex -p <name> exec "…"`）。
  効かないと分かった設定は残さず git から戻す（守らせているように見えて紛らわしい）。
- 棚卸しの「強制済みなので削れる」も、自分で読み直してから削る。許可（`permissions` の allow）があっても、
  system prompt の指示を打ち消す文（「`open` は自分で打つ」）は残す。worker 向けの指示ファイルのように複数の実行環境（Claude・Codex・pi など）が読む文は、
  全部の実行環境で強制されているときだけ縮める（2026-11-26 の棚卸しで、削ってよいとされた 8 か所のうち、実際に縮める価値があったものは無かった）。
