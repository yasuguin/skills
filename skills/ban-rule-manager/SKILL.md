---
name: ban-rule-manager
description: "「〜を禁止する」系ルールを、prose だけに頼らず hook 化して管理する skill。ui-banned-pattern.json（Write/Edit/NotebookEditの書き込み内容を対象。トースト、明朝体、グラデーション、window.confirm等）と command-banned-pattern.json（Bashコマンド文字列を対象。npm/pip/pipx等）の2つのregistryへのルール追加・編集・削除と、Claude以外のエージェントが書いた既存コードも含めた遡及スキャンを行う。ユーザーが「禁止ルールをhookに追加して」「このパターンを禁止したい」「既存コードに違反がないかスキャンして」のように依頼したときに使う。"
disable-model-invocation: true
---

# ban-rule-manager

「〜を禁止する」という prose ルールは、繰り返し破られたり、Claude Code の PreToolUse hook が
無い agent (Codex 等) が書いたコードをすり抜けたりする。このskillは、禁止ルールを
**registry (JSON)** で一元管理し、hook はそれを読むだけの汎用エンジンにすることで、
ルール追加を JSON 編集だけで完結させる。さらに hook では防げない **既存コードへの遡及適用**
（hook 導入前のコード、他 agent が書いたコード）を repo 横断スキャンで補う。

新しい prose ルールを丸ごと hook 化する一般的な判断（何を hook 化してよいか）は
`agent-doctor` skill のルールの最適化（`references/rule-placement.md`）の管轄。このskillは「禁止パターン」という決まった型の
ルールに特化し、その registry と遡及スキャンの実務を担う。

## 2つの registry

| registry | 対象 | 検査タイミング | 例 |
|---|---|---|---|
| `ui-banned-pattern.json` | Write/Edit/NotebookEdit の書き込み内容（拡張子でスコープ） | ファイル編集時 | トースト、明朝体、グラデーション、`window.confirm` |
| `command-banned-pattern.json` | Bash コマンド文字列 | コマンド実行時 | `npm`、`pip`、`pipx install`、`poetry` |

hook の実体は 1 つの汎用エンジン `scripts/validate-banned-patterns.sh` で、第 1 引数の `ui` / `command` で
registry を切り替え、第 2 引数で registry のパスを受ける（省略時はエンジンと同じディレクトリの
`<mode>-banned-pattern.json`）。前処理の `scripts/strip-shell-literals.pl` を同じディレクトリに置く。
必要なのは `jq` と `perl` で、`jq` が無ければ何もせず通す。


**2つを分けている理由**: UI系のルール（`linear-gradient` 等）を Bash コマンド文字列にも
適用すると、`rg 'linear-gradient'` のような正規の検索コマンド自体を誤検知で block してしまう。
書き込み内容とコマンド文字列は別物として扱う。
command 側は照合の前に引用符の中身と heredoc の本文を除く。commit メッセージや grep の検索語に書いただけの語が
止まらないようにするため（`bash -c` の引数や `"$(...)"` は実行されるので除かない）。

## 入れる（初回だけ）

1. エンジンと前処理を hook の置き場へ写し、`assets/` のサンプルを registry として隣に置く。

   ```sh
   mkdir -p ~/.claude/hooks
   cp scripts/validate-banned-patterns.sh scripts/strip-shell-literals.pl ~/.claude/hooks/
   cp assets/ui-banned-pattern.example.json ~/.claude/hooks/ui-banned-pattern.json
   cp assets/command-banned-pattern.example.json ~/.claude/hooks/command-banned-pattern.json
   ```

2. `~/.claude/settings.json` の `hooks.PreToolUse` に 2 つ登録する（既にある配列には足す）。

   ```json
   {
     "hooks": {
       "PreToolUse": [
         { "matcher": "Bash", "hooks": [{ "type": "command", "command": "bash \"$HOME\"/.claude/hooks/validate-banned-patterns.sh command" }] },
         { "matcher": "Write|Edit|NotebookEdit", "hooks": [{ "type": "command", "command": "bash \"$HOME\"/.claude/hooks/validate-banned-patterns.sh ui" }] }
       ]
     }
   }
   ```

3. 止まるかを 1 件ずつ確かめる。違反なら `{"decision":"block","reason":"…"}` が出て、違反でなければ何も出ない。

   ```sh
   echo '{"tool_name":"Write","tool_input":{"file_path":"a.css","content":"a{background:linear-gradient(red,blue)}"}}' \
     | bash ~/.claude/hooks/validate-banned-patterns.sh ui
   ```

## rule のスキーマ

```json
{
  "id": "ui-no-toast",
  "skill": null,
  "extensions": ["ts", "tsx", "js", "jsx"],
  "deny_patterns": ["from ['\"]sonner['\"]", "from ['\"]react-hot-toast['\"]"],
  "allow_patterns": [],
  "message": "トーストのライブラリは入れません。結果は画面の中の状態表示で返してください"
}
```

- `id`: 一意な識別子
- `skill`: 違反時に誘導する既存skill名（無ければ `null`）。既存の除去/移行skillがある禁止パターンは、
  hookは「防ぐ」だけに徹し、除去はそのskillに委ねる
- `extensions`: `ui` registry限定。対象拡張子（省略/空配列は遡及スキャン非対応になる。後述）
- `path_patterns`: `ui` registry限定。対象ファイルパスに対する ERE 正規表現の配列（任意）。
  どれか1つに当たったファイルだけが対象。`extensions` と併用したときは両方を満たすものだけ対象。
  拡張子で表せない対象（拡張子の無い `Dockerfile`、「テストファイルだけ」）を絞るための欄。
  apply_patch は差分内のどれか1つのファイルパスに当たれば対象にする（ファイル単位では絞らない）
- `deny_patterns` / `allow_patterns`: ERE正規表現の配列。`allow_patterns` は同一コマンド文字列
  （command registry）または同一行（ui registry）内で1つでもマッチしたら例外として許可する
- `message`: block時の理由文。何が禁止で代わりに何を使うかを明記する

## ルールを追加する手順

1. 対象の registry（`ui-banned-pattern.json` または `command-banned-pattern.json`）に rule を 1 件足す
2. 誤検知チェック: 禁止したいパターンと表面上似ているが許可すべき正当なケースを最低1つ考え、
   `allow_patterns` で除外できるか確認する（`references/false-positive-checklist.md` 参照）
3. block されるべき入力と許可されるべき入力の両方を、「入れる」の 3 と同じ形でエンジンに流して確かめる。
   繰り返し使うケースは、手元の hook のテストに足しておく

新しいルールを1件追加するのに `validate-banned-patterns.sh` 自体を編集する必要はない。
編集が要るのはエンジンの挙動そのものを変えるとき（新しいマッチ条件の種類を足す等）だけ。

## 既存コードへの遡及スキャン

hook は「これから書かれる」違反しか防げない。hook 導入前のコードや、Codex など
Claude Code 以外の agent が書いたコード（このagentのhookをすり抜けている）は、
repo を横断スキャンして見つける。

```sh
uv run --no-project scripts/scan_ui_patterns.py <target_dir> <ui-banned-pattern.json のパス>
```

- 出力は rule ごとにグルーピングされた `file:line` 一覧
- `extensions` も `path_patterns` も空のルールはスキャン対象外（対象を絞れないルールは誤検知が広がりすぎるため）。
  `path_patterns` だけのルールは全ファイルからパスで絞って走査する（Dockerfile・テストファイル用）
- **command registry には遡及スキャンが無い**。過去に実行した Bash コマンドは対象ファイルとして
  残らないため、静的スキャンで見つけようがない。command 側は prevention 専用と割り切る

### 見つかった違反への対応

このskill自身は違反を **修正しない**（レポートまで）。修正は rule の `skill` フィールドが
指す skill に委ねる（`null` なら、ユーザーと 1 件ずつ直し方を決める）。理由: 除去には「本当に不要な用法か」の
UI 判断が伴い、それぞれの skill が持つ「禁止しないもの」の例外知識を再利用すべきだから。

ユーザーには rule ごとの件数と一覧を提示し、対応する skill を実行してよいか確認してから進める。


## Codex 対応について

Codex は `command-banned-pattern.json` / `ui-banned-pattern.json` を PreToolUse hook から
読み込まない。コマンドの許可・確認・禁止は `~/.codex/rules/default.rules`、内容の検査は
Codexのhookではなく通常のレビューや検証へ委ねる。このskillのregistryとエンジンはClaude Codeの
PreToolUse専用であり、Codexから共用しない。
