# Agent-Friendly CLI ガイダンス

AI Agent と人間の両方が使う CLI を作るときの詳細ガイダンス。SKILL.md の workflow から参照される。出典の一覧と根拠の種類（出典・取り決め・経験則）は [sources.md](sources.md)。

## 中心方針

**data と presentation を分離する。** 内部ロジックは構造化データを返す engine として扱い、人間向け TUI や色付き表示は renderer の 1 つとして実装する。同じ `watch` が、人には更新し続ける TUI を、エージェントには NDJSON の event を返す。（出典: [Google Cloud Tech][gct]）

## Agent の context window を守る

Agent が処理する default output は短く、重要順にする。（出典: [Google Cloud Tech][gct]、[Anthropic: token efficiency][anthropic]、[clig: Output][clig-output]）

- 長大な本文、log、diff、blob は truncate する。（出典: [Google Cloud Tech][gct]、[Anthropic][anthropic]）
- truncate したら、次にどう絞ればよいか（filter・page・`--full`）を出力に書く。エージェントは省略に気づかず、そのまま結論を出すため。（出典: [Anthropic][anthropic]）
- secrets、tokens、API keys は mask する。会話のログへ漏らさないため。（出典: [Google Cloud Tech][gct]）
- raw payload が必要な場合だけ `--full` / `--verbose` のような明示 opt-in を要求する。（出典: [Google Cloud Tech][gct]）秘密を見せる opt-in を分けるときの名前（`--include-secret-values` など）は、経験則で決めてよい。
- severe / actionable / pending な項目を上に sort する。（出典: [Google Cloud Tech][gct]）
- ID だけでなく、人が読める名前も返す。エージェントは UUID より名前のほうを取り違えにくい。（出典: [Anthropic][anthropic]）

Agent に「あとで自分で大量 data を処理して重要項目を探せ」と押し付けない。CLI 側で重要度順に pre-process する。（出典: [Google Cloud Tech][gct]）

## 入力を信頼しない

エージェントは打ち間違えるだけでなく、もっともらしい誤り（存在しないフィールド名、二重に encode したパス、別の ID の流用）を入れてくる。（出典: [Poehnelt][poehnelt]）

- 引数は CLI 側で検証し、誤りは `Hint:` 付きで早く返す。重い処理や API 呼び出しの前に、設定と接続を確かめる（早く失敗する）。（出典: [Google Cloud Tech][gct]、[Poehnelt][poehnelt]）
- 変更を伴う command には `--dry-run` を付け、何が起きるかを先に見せる。（出典: [Poehnelt][poehnelt]、[clig: Arguments and flags][clig-args]）
- 引数や出力の形をエージェントが実行時に引けるようにする（`--describe` で command の引数と出力の形を JSON で返す、など）。`--help` の文章より確実に読める。（出典: [Poehnelt][poehnelt]）
- 外部から取ってきた文字列（Web ページ、メール、ユーザー投稿）を出すときは、エージェントへの指示として読まれ得ることを前提に、データだと分かる形で返す。（出典: [Poehnelt][poehnelt]）
- 引数名は曖昧にしない（`user` ではなく `user_id`）。（出典: [Anthropic][anthropic]）

## State を閉じ込めない

Agent を CLI process 内の interactive loop に閉じ込めない。（出典: [Google Cloud Tech][gct]）

- 長時間 workflow は backend / file / service 側に state を持たせる。（出典: [Google Cloud Tech][gct]）
- CLI は `--task <id>` のような reference id で状態を参照する。（出典: [Google Cloud Tech][gct]）
- watch / get / cancel / resume のような stateless command を用意する。（経験則。上の 2 つを command に落とした形）
- conversation history や token context は CLI process ではなく外部 state に置く。（出典: [Google Cloud Tech][gct]）

## Config と context を標準化する

- config は XDG に従う。`$XDG_CONFIG_HOME/<app>/`、未設定か空なら `~/.config/<app>/` に置く。（出典: [XDG][xdg]、[clig: Configuration][clig-config]、[Google Cloud Tech][gct]）ファイル名は `config.yaml` を既定にする。（出典: [Google Cloud Tech][gct]）
- home 直下の独自 dotfile を増やさない。（出典: [Google Cloud Tech][gct]）
- 設定の優先順位は、flag > 環境変数 > プロジェクトの設定 > ユーザーの設定 > システムの設定。（出典: [clig: Configuration][clig-config]）
- local / staging / prod など named environment を `--env` で選べるようにする。orchestrator は `--env prod` だけで、URL やトークンを知らずに文脈を切り替えられる。（出典: [Google Cloud Tech][gct]）
- URL や token を毎回 flag で渡させない。秘密は flag で受けない（`ps` やシェルの履歴に残る）。（出典: [Google Cloud Tech][gct]、[clig: Arguments and flags][clig-args]）
- 環境変数の名前は大文字・数字・下線だけにし、広く使われる名前を奪わない。（出典: [clig: Environment variables][clig-env]）

## 非対話 mode の自動判定

次の条件では interactive UI（prompt・spinner・TUI）を避ける。（出典: [Google Cloud Tech][gct]、[clig: Interactivity][clig-interactive]）

- stdin / stdout が terminal ではなく pipe / file になっている。（出典: [clig: Interactivity][clig-interactive]、[clig: Output][clig-output]）
- `<APP>_NO_TUI` が set されている。（出典: [Google Cloud Tech][gct]）
- `--no-input` が渡された。（出典: [clig: Interactivity][clig-interactive]）
- CI で実行されている。（経験則）

`NO_COLOR` は色を止めるだけにし、対話を止める条件には使わない。NO_COLOR の仕様が定めるのは色だけで、色を嫌う人が対話まで失うと困るため。（出典: [NO_COLOR][no-color]。[Google Cloud Tech][gct] は NO_COLOR でも対話を止めるとするが、ここでは仕様のほうに合わせる）

必須の入力が足りず対話もできないときは、待ち続けずに「どの flag で渡すか」を出して終わる。（出典: [clig: Interactivity][clig-interactive]）

destructive action では自動 confirm に頼らず、`--yes`、`--force`、`--confirm <resource-name>` のような明示 flag を要求する。危険度で段階を分ける: 小さい（元に戻せる）なら確認なし、中くらいなら確認、大きい（全消去など）なら対象の名前を打たせる。（出典: [clig: Arguments and flags][clig-args]、[Google Cloud Tech][gct]）

## Terminal color の設計

color は aesthetic ではなく state の伝達に使う。（出典: [Google Cloud Tech][gct]、[clig: Output][clig-output]）

色は名前ではなく役割で決める。（出典: [Google Cloud Tech][gct]）

- accent: 見出し・グループ名・節のラベル
- command: command 名・flag
- pass: 成功
- warn: 警告・実行中・保留
- fail: 失敗・拒否
- muted: メタデータ・既定値・プレビュー
- id: ID

注意:
- description や help text に色を付けすぎない。（出典: [Google Cloud Tech][gct]）
- 階層は色より余白・位置・まとまりで作る。（出典: [Google Cloud Tech][gct]）
- light / dark どちらの terminal でもコントラストを保つ。（出典: [Google Cloud Tech][gct]）
- 色を止める条件: `NO_COLOR` が空でない値、`TERM=dumb`、`--no-color`、出力が TTY でない。（出典: [NO_COLOR][no-color]、[clig: Output][clig-output]）

## Lifecycle

- `--version` を実装する。大きな更新があれば、必要に応じて知らせる。（出典: [Google Cloud Tech][gct]、[clig: Arguments and flags][clig-args]）
- `SIGINT` を graceful に扱い、途中終了で data corruption を起こさない。後始末が済んでいない状態からも起動できるようにする。（出典: [Google Cloud Tech][gct]、[clig: Signals][clig-signals]）
- Ctrl-C ですぐ止まれないときは、もう一度押すと何が起きるかを出す。（出典: [clig: Signals][clig-signals]）
- 書き込みの操作では、誰がやったか（`git config user.name` や `$USER`、service account 名）を記録する。（出典: [Google Cloud Tech][gct]）

## Repository Guidance for Agents

CLI が Agent に使われる前提なら、repo 側にも使い方を置く。（出典: [Google Cloud Tech][gct]、[Poehnelt][poehnelt]）

- root に `AGENTS.md` を置き、default workflow、禁止事項、architecture standard を書く。（出典: [Google Cloud Tech][gct]）
- 複雑な workflow は `skills/` や dedicated prompt file として外部化する。（出典: [Google Cloud Tech][gct]、[Poehnelt][poehnelt]）
- Agent が tool の使い方を native に知っていると仮定しない。暗黙の前提（用語、ID の形、関係）は説明に書く。（出典: [Google Cloud Tech][gct]、[Anthropic][anthropic]）
- `--help`、README、AGENTS.md、skill の説明が矛盾しないようにする。（取り決め: 正本は 1 箇所）

## Output mode 詳細

- `--json`: 1 回の結果を JSON で返す。（出典: [Google Cloud Tech][gct]、[clig: Output][clig-output]）
- `--no-tui` または `--plain`: interactive renderer を無効化する。（出典: [Google Cloud Tech][gct]）`--plain` は clig では「grep しやすい 1 行 1 件のテキスト」の意味だが、ここでは装飾を抑える意味で使う。（取り決め: 手元の 21 ツールがこの意味で使っている。2026-11-25 に維持を決めた）
- watch / stream 系は NDJSON を使い、1 line = 1 event にする。各行は UTF-8 の 1 つの JSON で、行の中に改行を含めず、`\n` で終える。（出典: [Google Cloud Tech][gct]、[NDJSON][ndjson]、[JSON Lines][jsonl]）
- stderr は diagnostics、stdout は data に分ける。（出典: [clig: The Basics][clig-basics]）
- machine mode では spinner、progress bar、color escape、prompt を出さない。（出典: [Google Cloud Tech][gct]、[clig: Output][clig-output]）
- `-` を標準入力・標準出力として受け、`--` 以降はオプションとして解釈しない。（出典: [POSIX Utility Syntax Guidelines][posix-args]）

```sh
# Human: live TUI
tool watch --task abc123

# Agent: parseable event stream
tool watch --task abc123 --no-tui
```

[gct]: https://x.com/GoogleCloudTech/status/2038778093104779537
[anthropic]: https://www.anthropic.com/research/writing-tools-for-agents
[poehnelt]: https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/
[clig-basics]: https://clig.dev/#the-basics
[clig-output]: https://clig.dev/#output
[clig-args]: https://clig.dev/#arguments-and-flags
[clig-interactive]: https://clig.dev/#interactivity
[clig-signals]: https://clig.dev/#signals
[clig-config]: https://clig.dev/#configuration
[clig-env]: https://clig.dev/#environment-variables
[no-color]: https://no-color.org/
[xdg]: https://specifications.freedesktop.org/basedir/latest/
[ndjson]: https://github.com/ndjson/ndjson-spec
[jsonl]: https://jsonlines.org/
[posix-args]: https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap12.html#tag_12_02
