# 出典

cli-creator の主張の根拠の一覧。各ファイルでは、主張の直後に出典を付けている。根拠の種類は次の 4 つ。

- **出典**: 下の一覧の資料。リンクは各ファイル末尾の参照リンクに置く。
- **取り決め**: 外部の出典ではなく、作者の環境・好み・過去の失敗から決めたもの。どこで決めたかを書く。
- **経験則**: 一般に言われるが、一次情報が見つかっていないもの。新しい出典が見つかったら差し替える。
- **実測**: 実際に動かして確かめた事実（いつ・何で確かめたかを書く）。ライブラリの版が上がったら確かめ直す。

2026-11-25 に、下の資料を読んで主張と突き合わせた。「本文未確認」と書いたものは、要約や目次までしか読めていない。

## CLI 設計の指針

- **Google Cloud Tech「Build a CLI for AI agents & humans in less than 10 mins」**（X の記事、2026-03-31、@ghchinoy・@Saboo_Shubham_・Zack Akil）https://x.com/GoogleCloudTech/status/2038778093104779537
  - エージェントと人の両方に向けた CLI の設計。この skill の中心方針・エージェント向けの節の下敷き。X はログインが要る（未ログインの WebFetch は HTTP 402）ので、ログイン済みのブラウザで読む。
  - 主な主張: data と presentation の分離、`--help` から入る、機能別のグループと `(start here)`、例 3〜5 個、`AGENTS.md` と `skills/`、全 command に `--json` / `--no-tui`、`NO_COLOR` と `[APP]_NO_TUI` と pipe で対話を止める、出力を短く重要順に・秘密を隠す・`--full` / `--verbose` で全量、`--task <ID>` で状態を外に置く、XDG と `--env`、`Hint:`、早く失敗する、終了コード 0/1/2/3、短縮フラグを揃える、中心の対象は positional、安全な既定、色の役割、`--version`、`SIGINT`、書き込んだ人の記録。
  - 参照元として次の 2 つを挙げている: beads の UI_PHILOSOPHY.md https://github.com/steveyegge/beads/blob/main/docs/UI_PHILOSOPHY.md （本文未確認）と clig.dev。
- **Command Line Interface Guidelines（clig.dev）** https://clig.dev/
  - 人向けの CLI の作法の総まとめ。節: [The Basics](https://clig.dev/#the-basics)・[Help](https://clig.dev/#help)・[Documentation](https://clig.dev/#documentation)・[Output](https://clig.dev/#output)・[Errors](https://clig.dev/#errors)・[Arguments and flags](https://clig.dev/#arguments-and-flags)・[Interactivity](https://clig.dev/#interactivity)・[Subcommands](https://clig.dev/#subcommands)・[Robustness](https://clig.dev/#robustness-guidelines)・[Signals](https://clig.dev/#signals)・[Configuration](https://clig.dev/#configuration)・[Environment variables](https://clig.dev/#environment-variables)。
- **Anthropic「Writing effective tools for agents — with agents」** https://www.anthropic.com/research/writing-tools-for-agents
  - エージェントが呼ぶ道具の設計。出力の切り詰め方、自然言語の名前、引数名、例の載せ方、失敗の伝え方。
- **Justin Poehnelt「You Need to Rewrite Your CLI for AI Agents」**（2026-03-04）https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/
  - Google Workspace CLI の設計を説明した個人ブログ（Google の公式文書ではない）。入力の検証、`--describe`、`--dry-run`、応答のサニタイズ、入口を 1 つの正本から作ること。

## 規格・仕様

- **NO_COLOR** https://no-color.org/ — `NO_COLOR` が空でない値なら ANSI の色を付けない。定めているのは色だけ。
- **XDG Base Directory Specification** https://specifications.freedesktop.org/basedir/latest/ — 設定は `$XDG_CONFIG_HOME`、未設定か空なら `$HOME/.config`。
- **NDJSON** https://github.com/ndjson/ndjson-spec ／ **JSON Lines** https://jsonlines.org/ — 1 行 1 つの JSON、UTF-8、行の中に改行を含めない、各行の終わりに `\n`。
- **POSIX Utility Syntax Guidelines** https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap12.html#tag_12_02 — Guideline 10 の `--` はオプションの終わり、13 の `-` は標準入力・標準出力。
- **RFC 9457 Problem Details for HTTP APIs** https://www.rfc-editor.org/rfc/rfc9457.html — 標準のメンバーは type・status・title・detail・instance。他は拡張メンバー（§3.2）。
- **Unicode UAX #11 East Asian Width** https://www.unicode.org/reports/tr11/ — F・W は全角、Na・H は半角、A（Ambiguous）は文脈で決まらなければ半角扱い（§5）。端末での利用は意図していない（§2）。結合文字の値は表示幅と一致しない（§6.2）。
- **Bash Reference Manual: Exit Status** https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html — 番号 N のシグナルで終わったら 128+N（SIGINT なら 130）。gnu.org は続けて取得すると HTTP 429 になる。
- **GNU Readline Library: Redisplay** https://tiswww.case.edu/php/chet/readline/readline.html#Redisplay — プロンプト中の幅を取らない文字を `RL_PROMPT_START_IGNORE`（`\001`）と `RL_PROMPT_END_IGNORE`（`\002`）で囲む（本文未確認。目次と要約で確認）。
- **GitHub CLI: exit codes** https://cli.github.com/manual/gh_help_exit-codes — 0 成功・1 失敗・2 キャンセル・4 要認証。終了コードの割り当ては CLI ごとに割れている例。
- **sysexits(3)** https://man.freebsd.org/cgi/man.cgi?query=sysexits&sektion=3 — 64 以降の値を定めるが、同じページで非推奨とされている。使わない根拠。

## Python・ツールの公式ドキュメント

- argparse https://docs.python.org/3/library/argparse.html — 使い方の誤りは終了コード 2。`allow_abbrev`。3.14 からは親の `usage=` がサブパーサの `prog` に影響しない。
- shutil.get_terminal_size https://docs.python.org/3/library/shutil.html#shutil.get_terminal_size — `COLUMNS`、端末、fallback の順に幅を決める。
- textwrap https://docs.python.org/3/library/textwrap.html — 幅は文字数で数える（全角を考えない）。
- unicodedata https://docs.python.org/3/library/unicodedata.html — `east_asian_width`、`combining`。
- input https://docs.python.org/3/library/functions.html#input — プロンプトは標準出力に書かれる。readline が読み込まれていれば使う。
- uv https://docs.astral.sh/uv/guides/projects/ ・ https://docs.astral.sh/uv/reference/cli/ — `uv run`、依存と lockfile。
- pyproject.toml https://packaging.python.org/en/latest/guides/writing-pyproject-toml/ — `[project.scripts]` でコマンドを登録する。
- Typer https://typer.tiangolo.com/ ・ Click https://click.palletsprojects.com/ ・ Rich https://rich.readthedocs.io/en/stable/console.html — フレームワークと表示の部品。

uv・packaging・Typer・Click・Rich の URL は、2026-11-25 には取得し直していない。
