# hook 実装の規約（Claude Code / Codex）

対象repoの既存 hook を読んだうえで、そのrepo固有の規約に合わせて実装すること。
ここに書くのは作者の環境で実際に使われているパターンで、他repoでは
異なる場合がある。**必ず対象repoの既存hookを先に読み、そちらを優先する。**

## Claude Code: `.claude/hooks/*.sh` + `.claude/settings.json`

- PreToolUse hook は stdin から JSON を受け取り、`tool_name` / `tool_input.*` を
  `jq` で取り出す。`jq` が無いときの扱いは hook ごとに違う（`validate-tool-policy.sh` は `grep -o` で取り出し、
  `validate-banned-patterns.sh`・`deploy-grant.sh` は何もせず `exit 0`）。同じ hook の既存の書き方に合わせる。
- 応答は3種類。ファイル内の既存 helper 関数名に合わせる。
  - `block()` — `{"decision":"block","reason":"..."}` を返し実行を止める
  - `ask()` — `permissionDecision:"ask"` を返しユーザー確認を挟む（settings.json の
    allow リストで素通りしてしまう操作に使う）
  - `recommend()` — Claude Code 側の既存契約に合わせる。Codexへ共用せず、Codexのコマンド判定は
    `.codex/rules/default.rules`へ置く。
- 新しいルールを既存の汎用policy hook（例: `validate-tool-policy.sh`）に追記できるなら
  そちらを優先し、1ルール1ファイルには分割しない。ファイル冒頭のコメントで
  「このhookが何を強制しているか」の一覧を更新する。
- `settings.json` の hooks 配列自体への登録変更が必要な場合は、このskillではなく
  `update-config` skill に委ねる（settings.json のスキーマ管理はそちらが正本）。

## Codex: `.codex/hooks.json` + `.codex/hooks/*`

Codex のコマンド許可・確認・禁止は、まず `.codex/rules/default.rules` に置く。
`prefix_rule` は argv の prefix を照合し、複数一致時は `forbidden > prompt > allow` の
最も厳しい判定を採用する。prefix で判定できる危険コマンドを Codex の PreToolUse hook で再検査しない。

Codex hook を使うのは、rules/config では表現できないものに限る。Stop 時の quality gate、通知、
transcript からの skill usage 記録、memory/commit reminder などのライフサイクル処理と、prefix では判定できない
Bash の検査（push 先の判定の `validate-push.sh`、gh の対象 repo の `validate-gh-target.sh`、
`git-cleanup-policy.py`）が該当する。
同期 hook は操作の継続前に完了を待つため、通常の Bash 呼び出しへ複数の shell hook を追加しない。
速度を理由に `async` へ変更する場合も、非同期 hook は対象操作を block、approve、rewrite できない点を確認する。

追加前に `codex execpolicy check --pretty --rules ~/.codex/rules/default.rules -- <command>` で
rules による代替を確認し、hook を追加する場合は対象イベントの worst-case wall time を実測する。

以下は Codex の PreToolUse を新しく足すときの技術メモ。作者の環境では、prefix で判定できる
危険コマンドは rules に集約し、PreToolUse(Bash) は上の 3 本だけにしている。

- `.codex/hooks.json` の `hooks.PreToolUse` は `matcher` ごとの配列。`matcher: "Bash"` の他に
  `matcher: "apply_patch"`（Codex のファイル編集ツール、Write/Edit 相当）が使える。
  `"Write"`/`"Edit"` は `apply_patch` の matcher alias として機能するが、実際に
  hook stdin へ乗る `tool_name` の値は常に `apply_patch` になる（`Write`/`Edit` という
  値そのものは来ない。tool_name 判定の条件分岐は必ず `apply_patch` を見る）。
- **過去の実装検証:** Codex の hook は Python 実装が基本という前提を鵜呑みにしない。2026-08 時点の検証で、
  `Bash` と `apply_patch` の `tool_input` はどちらも `{"command": "..."}` という
  Claude Code の Bash hook と同じ形（`codex-rs/core/src/tools/registry.rs` の
  `PreToolUsePayload` コメント "Shell-like tools use `{ "command": ... }`" で裏取り済み）。
  そのため Claude Code 用 bash hookをCodexへ移植すること自体は技術的には可能だが、
  作者の環境では共有しない。
  Python への書き直しは、Codex 固有の挙動（後述の `ask` 未サポート等）を吸収する分岐が
  bash 側の可読性を大きく損なう場合や、対象 repo の既存 Codex hook が Python 実装で
  統一されている場合の選択肢として残す。
- `apply_patch` の `tool_input.command` には `file_path` のような個別フィールドは無く、
  次の形式の diff テキスト全体が1つの文字列として入る。
  ```
  *** Begin Patch
  *** Update File: <path>
  @@
  -old line
  +new line
  *** End Patch
  ```
  ファイルパスが必要な hook（管理対象のファイルかの判定など）は
  `grep -oE '^\*\*\* (Add|Update|Delete) File: .+'` でヘッダー行を抽出し、
  複数ファイルを含む1回の `apply_patch` 呼び出しに対応する（1ファイル前提で
  `file_path` を直接読む実装を流用しない）。拡張子スコープが必要な hook
  （`ui-banned-pattern.json` 等）も、抽出した全ファイルパスの拡張子一覧のうち
  1つでも対象拡張子に一致すればルールを適用する形にする（単一ファイル `file_path`
  前提の拡張子判定をそのまま複数ファイルには使えない）。
- **`permissionDecision:"ask"` は Codex では未サポートで hook failed になり、ツール呼び出しが継続する。**
  [公式 Hooks ドキュメント](https://learn.chatgpt.com/docs/hooks) の `PreToolUse` 節にあるとおり、
  `ask` を確認 UI の代用にしてはいけない。確認後にエージェント自身が実行できる操作は、hook が
  decision を返さず Codex の通常承認フローへ委ねる。実行自体を禁止する要件だけは `deny` を使う。
- **`permissionDecision:"allow"` は `updatedInput` と併用する場合だけ有効。** Bash と
  `apply_patch` では `updatedInput.command` が必要。コマンドを書き換えずに理由や推奨だけを
  伝える場合は、`permissionDecision` を返さず `additionalContext` のみを返す。
- `PreToolUse` の安全性を確認するときは、hook の JSON 出力を文字列検索だけでなく JSON として
  検証し、decision の有無、`updatedInput` の必須フィールド、stdout に余計なログがないことを
  確認する。`ask` を `deny` に機械的に置き換えると、ユーザー確認後もエージェントが実行できない
  運用変更になるため、要件として「禁止」か「確認後に実行可」かを分けて承認を取る。
- Read 相当の専用 `tool_name` は 2026-08 時点で確認できていない。Codex はファイル読み取りも
  `cat`/`sed -n` 等の Bash コマンド経由で行っている可能性が高く、その場合 Bash 向けの
  読み取り検出ロジック（例: `validate-secret-access.sh` の `READER_RE`）が実質カバーする。
- 過去に `.codex/hooks.json` と Python 実装（例: `prevent-dangerous-bash.py`）が
  併存していた場合は、二重実装のまま残さず、現在は危険コマンド判定を
  `.codex/rules/default.rules` へ移す。片方だけ更新して同期が崩れる事故を防ぐ。
- 未知の挙動を推測で実装しない。公式ドキュメント（2026-08時点は
  https://developers.openai.com/codex/hooks から https://learn.chatgpt.com/docs/hooks
  へ 308 redirect）だけでなく、`gh api repos/openai/codex/contents/<path>` で
  `codex-rs/hooks/src/events/*.rs` や `codex-rs/core/src/tools/*.rs` のテストコードまで
  実際に読んで裏取りする。ドキュメントに書かれていない挙動が、テストコードのアサーションで
  確定的に分かることがある（`ask` が hook failed になって処理継続する挙動はその一例）。

## 両方に実装すべきか判断する

- **Claude Code側のhookとCodex側のrulesに分担する**: どちらのエージェントにも必要な
  コマンド判定でも、同じhookを二重実装しない。Claude Codeは既存hook/registry、Codexは
  `.codex/rules/default.rules`を使う。
- **Codex hookに残す**: StopやSessionStartなど、rules/configでは表現できないライフサイクル処理。
- **片方でよい**: 特定エージェント固有の挙動に関するルール（例: Claude Code の
  サブエージェント運用ルール）。
- 判断に迷ったら、instruction file 側の記述がどちらのエージェント向けかを確認する
  （`.claude/` 配下限定の記述か、両方に共通する `AGENTS.md`/`CLAUDE.md` の記述か）。
- **技術的・仕様的に Codex 側へ移植できない場合は、無理に作らず見送ってよい。** 例:
  対応する `tool_name`/hook event が存在しない、ペイロード構造が確認できずロジックの
  正しさを検証できない、`ask` 相当の挙動が必須だが `deny` への降格をユーザーが
  望まない等。見送る場合は、その旨と理由（確認した公式情報・試した検証方法を含む）を
  コミットの詳細メッセージか、見送った箇所の近接コメントに残し、
  「未検証のまま配線しない」ことを明記する。調査記録の doc は repo に増やさない。

