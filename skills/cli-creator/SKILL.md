---
name: cli-creator
description: CLI を作る・直す・設計を確かめるときに使う。新規ツールも、サービスの API を叩く CLI（MCP・API と並ぶ入口）も、command 構成・--help の例・--json・失敗のヒントと終了コード・テストまで揃える。対話起動の起動画面と入力欄も。
---

# CLI Creator

最高の CLI を作るための skill。単に動く script を作るのではなく、人間にも AI Agent にも使いやすい command-line product として仕上げる。

**中心方針: data と presentation を分離する。** 内部ロジックは構造化データを返す engine、人間向け TUI や色付き表示は renderer の 1 つとして実装する。（出典: [Google Cloud Tech][gct]）Agent-friendly な設計の詳細は [references/agent-friendly-cli.md](references/agent-friendly-cli.md) を参照。

**根拠の書き方**: 主張の直後に、出典（外部の資料）・取り決め（作者の環境や過去の失敗から決めたこと）・経験則（出典が見つかっていない一般論）・実測のどれかを付ける。一覧と各資料の要点は [references/sources.md](references/sources.md)。skill に主張を足すときも、同じように根拠を付ける。

サービスの API を叩く CLI で、MCP や HTTP API と並ぶ入口の 1 つになるとき（起動画面・対話より、エージェントとパイプが主な利用者）は、[references/service-client-cli.md](references/service-client-cli.md) の入口の揃え方・失敗の形・テストを先に読む。

## Core Defaults

- repo に既存の言語・ビルドがあればそれに合わせる（API の型を共有できる）。新規の単独ツールの既定は Python + `uv`。（取り決め: cli-creator の既定）
- 単発ツールでも、将来の変更を見越して `main(argv=None) -> int`、テスト可能な core logic、README、実行例を用意する。（取り決め）
- 他言語のほうが適切なら、理由を明示して選ぶ。（経験則）
  - shell: 依存なしの薄い wrapper や glue script
  - Go / Rust: 単一バイナリ配布、速度、並行処理、OS 横断が重要
  - Node.js / TypeScript: 既存 ecosystem や frontend tooling と密接
- Python CLI framework は repo と用途で選ぶ。（経験則。各フレームワークの機能は [sources.md](references/sources.md) の公式ドキュメント）
  - `argparse`: 依存を増やしたくない、小さめ、標準ライブラリで十分
  - `Typer`: 型ヒント中心で、help や subcommand を読みやすくしたい
  - `Click`: 既存 project が Click 系、plugin / command group を活かしたい
  - `Rich`: presentation renderer として使う。machine-readable output に混ぜない（出典: [clig: Output][clig-output]）

## Workflow

### 1. Product surface を決める

まず次を短く固定する。（取り決め: 作り始める前に決めておくと手戻りが減る項目）

- ツール名、対象ユーザー、1 行価値
- CLI コマンド名、project / package 名、起動画面のバッジに出す名前の対応
- 起動画面と入力欄に使う accent color
- 最初に実行する典型 command
- 入力元: positional URL / file / stdin / config / env
- 出力先: stdout / file / download directory / service
- human mode と machine mode の両方が必要か
- destructive action の有無

起動画面のバッジに出す名前は、原則として CLI の product / command 名と一致させる。既存有名 CLI と名前が重なる場合でも、personal tool、repo 内 tool、公開配布予定の有無を見て判断し、ユーザーの意図が明確なら短く気持ちよい名前を優先してよい。（取り決め）

起動画面の色は、ユーザーに希望色を聞く。ブランド色やドメイン色が明らかで、ユーザーもそれを示唆している場合は、その色を既定として提案または採用する。色を決めたら名前のバッジと入力欄の `?` / `›` を同じ accent color で揃え、`NO_COLOR` / 非 TTY / machine mode では色を出さない。（取り決め。色を止める条件の出典: [NO_COLOR][no-color]、[clig: Output][clig-output]）

その他が不明なら質問する。ただし小さい personal tool なら保守的に仮定して進める。

### 2. Architecture を分ける

次の分離を基本にする。（出典: [Google Cloud Tech][gct] の data と presentation の分離。4 つへの分け方は経験則）

- core engine: 入力を受け、JSON 互換の data model か明確な result object を返す
- CLI adapter: argv parse、env、config、exit code、stderr diagnostics を扱う
- renderer: human text / banner / table / JSON / NDJSON を出す
- side effects: file write、network、subprocess、download は境界に寄せる

presentation を core logic に混ぜない。これがテスト、Agent 利用、将来の `--json` 対応を楽にする。

### 3. Command surface を作る

- root `--help` だけで「何ができるか」「最初に何をすべきか」が分かるようにする。エージェントも人も `--help` から入る。（出典: [Google Cloud Tech][gct]、[clig: Help][clig-help]）
- `-h` と `--help` の両方で help を出し、他の flag があっても help を優先する。`-h` を別の意味に使わない。（出典: [clig: Help][clig-help]）
- command は機能別に group 化し、初手には `(start here)` のように明示する。（出典: [Google Cloud Tech][gct]）
- 各 command に、動詞で始まる 1 行の要約・詳しい説明・コピーして使える例 3〜5 個を付ける。例は説明文より効く。人は読む前にコピーし、エージェントは例から flag の形を推定する。（出典: [Google Cloud Tech][gct]、[clig: Help][clig-help]、[Anthropic][anthropic]）
- 中心の対象（URL・ファイル・ID）1 つは positional argument、それ以外の指定は `--flag`。（出典: [Google Cloud Tech][gct]。[clig: Arguments and flags][clig-args] は flag を優先するよう勧めるので、positional は中心の 1 つに限る。2026-11-25 に維持を決めた）
- shorthand は全 command で意味を揃える。例: `-o` は常に output 系。（出典: [Google Cloud Tech][gct]、[clig: Arguments and flags][clig-args]）
- subcommand や長い flag の省略形を受けない（argparse は `allow_abbrev=False`）。後から command を足したときに、省略形の意味が変わるため。（出典: [clig: Subcommands][clig-sub]、[argparse][argparse]）
- 知らない command を既定の command に流さず、exit 2 と、打ち間違いなら近い候補を出す。候補を勝手に実行はしない。（出典: [clig: Subcommands][clig-sub]、[clig: Errors][clig-errors]）
- `--version` を入れる。（出典: [Google Cloud Tech][gct]、[clig: Arguments and flags][clig-args]）
- 長い workflow は `start / status / get / cancel / resume` など stateless command に分ける。Agent を CLI process 内の interactive loop に閉じ込めない。（出典: [Google Cloud Tech][gct]。動詞の組は経験則）
- 既定の振る舞いは、いちばん安全でよく使う道にする。destructive action は `--yes` / `--force` / `--confirm <resource-name>` のような明示 flag を要求し、危険度で段階を分ける。（出典: [Google Cloud Tech][gct]、[clig: Arguments and flags][clig-args]）
- 変更を伴う command には `--dry-run` を付ける。（出典: [clig: Arguments and flags][clig-args]、[Poehnelt][poehnelt]）

### 4. Output mode を設計する

data-producing command には原則 structured mode を付ける。（出典: [Google Cloud Tech][gct]、[clig: Output][clig-output]）

- `--json`: 1 result = JSON
- `--plain` または `--no-tui`: prompt、spinner、color、起動画面を抑える。（`--no-tui` の出典: [Google Cloud Tech][gct]。`--plain` は clig では「grep しやすい 1 行 1 件」の意味だが、ここでは装飾を抑える意味で使う。取り決め: 手元の 21 ツールがこの意味で使っている）
- watch / stream: NDJSON (1 line = 1 event)（出典: [Google Cloud Tech][gct]、[NDJSON][ndjson]）
- stdout: data / normal result
- stderr: diagnostics、warnings、progress、hints（stdout と stderr の分け方の出典: [clig: The Basics][clig-basics]）

pipe（非 TTY）、CI、`<APP>_NO_TUI`、`--no-input` では interactive UI を自動で避ける。`NO_COLOR` と `TERM=dumb` と `--no-color` は色だけを止める。（出典: [clig: Interactivity][clig-interactive]、[Google Cloud Tech][gct]、[NO_COLOR][no-color]、[clig: Output][clig-output]。CI は経験則）

Agent の context window を守る設計:（出典: [Google Cloud Tech][gct]、[Anthropic][anthropic]）
- default output は短く、重要順に sort する
- 長大な log / diff / blob は truncate し、`--full` / `--verbose` で opt-in。truncate したら、次にどう絞ればよいかを出力に書く
- secrets / tokens は mask し、見せるときは明示の opt-in にする

config は XDG に従い `$XDG_CONFIG_HOME/<app>/config.yaml`（未設定なら `~/.config/<app>/config.yaml`）に置く。`--env prod` で named environment を切り替えられるようにする。（出典: [XDG][xdg]、[Google Cloud Tech][gct]）詳細は [references/agent-friendly-cli.md](references/agent-friendly-cli.md) を参照。

時間のかかる処理は 100ms 以内に何かを出し、長い処理には進捗を stderr に出す。（出典: [clig: Robustness][clig-robust]）

### 5. 起動画面と入力欄を作る（対話起動する CLI だけ）

対話起動で人が最初に見る画面と、続く問いかけは [references/startup-screen.md](references/startup-screen.md) に従う。既定はスマホの 40 桁でも崩れない形で、枠もブロックアートのロゴも使わない。名前のバッジ・1 行の説明・今の状態（出力先・既定の設定）・ヒント 1 行を出し、問いかけは「? 問い  既定 x」と「› 」の 2 行にする。折り返しは文字数ではなく表示幅で数える。（取り決め: 2026-11-25。根拠の詳細は startup-screen.md）エージェントとパイプが主な利用者の CLI（サービスの API を叩く CLI など）には作らない。

### 6. Error guidance と exit code

error は次の action まで示す。エージェントはヒントを読んで自分で直し、人はドキュメントを探さずに済む。（出典: [Google Cloud Tech][gct]、[clig: Errors][clig-errors]、[Anthropic][anthropic]）見出しは、本文が日本語の CLI でも英語の `Error:` / `Hint:` / `Warning:` にする。（取り決め: 2026-11-25 の作者の指定。grep しやすく、エージェントも見出しで見分けやすい）

```text
Error: output directory does not exist
Hint: run '<tool> ... --output ~/Downloads/<name>' or create the directory first
```

- 重い処理や API 呼び出しの前に、設定・認証・接続を確かめて早く失敗する。（出典: [Google Cloud Tech][gct]）
- 成功したときも、次に打つとよい command があれば 1 行で示す。（出典: [clig: Output][clig-output]）

exit code:（出典: [Google Cloud Tech][gct]。2 = 使い方の誤りは [argparse][argparse] とも一致。値の割り当ては CLI ごとに割れていて、[gh][gh-exit] は 4 = 要認証。sysexits は非推奨なので使わない）

- `0`: success
- `1`: general operation error
- `2`: invalid usage / bad flags / parse error
- `3`: auth / connection / prerequisite failure

操作が失敗したら non-zero にする。（出典: [clig: The Basics][clig-basics]）

### 7. Python + uv 実装ルール

実装は「8. Tests」の観点を 1 つずつ先にテストで書き、赤を確認してから通す（red-green）。（取り決め）

- root project なら `pyproject.toml` に dependency と `[project.scripts]` を置く。（出典: [pyproject.toml][pyproject]）
- 単発 script なら `uv run path/to/script.py` を README に書く。必要なら project script 化する。（出典: [uv][uv]）
- 外部依存追加時は `uv lock` まで更新する。（出典: [uv][uv]）
- エントリポイントは `main(argv=None, *, input_func=input, output=sys.stdout, error=sys.stderr) -> int`。`input_func` は対話プロンプトのテスト注入用。（取り決め: テストで入出力を差し替えるため）
- Ctrl-C（`KeyboardInterrupt`）と、問いかけ中の Ctrl-D（`EOFError`）は、**`main` 自身で**受け止めて「中断しました。」を stderr に出し、exit 130 にする。130 は SIGINT（2）で終わったときのシェルの値 128+2。（出典: [Bash: Exit Status][bash-exit]、[clig: Signals][clig-signals]）`[project.scripts]` から入るコマンドは `main` を直接呼ぶので、`if __name__ == "__main__":` に書いた try/except は通らず Traceback が出る。（実測: 2026-11-25、手元の 21 ツールで Ctrl-C・Ctrl-D とも Traceback が出ていた）
  ```python
  def exits_on_interrupt(main):
      @functools.wraps(main)
      def wrapper(*args, **kwargs):
          try:
              return main(*args, **kwargs)
          except (KeyboardInterrupt, EOFError):
              print("\n中断しました。", file=sys.stderr)
              return 130
      return wrapper

  @exits_on_interrupt
  def main(argv=None, *, input_func=input, output=sys.stdout, error=sys.stderr) -> int: ...

  if __name__ == "__main__":
      raise SystemExit(main())
  ```
  確かめるときは `python cli.py` ではなく、インストールしたコマンド（`uv run <command>`）を疑似 TTY（`script -q /dev/null`）で起動して Ctrl-C を送る。
- 色の判定（起動画面・入力欄）は `environ` 引数を受け、テストで `os.environ` を差し替えられるようにする。（取り決め）
- prompt / output / downloader / subprocess は注入できる形にしてテスト可能にする。（取り決め）

### 8. Tests と verification

7 の実装は、最低限、次を 1 つずつテスト先行で固定する。（取り決め）

- parser: default、invalid usage、主要 flag
- core engine: external API を mock / fake して contract を確認
- renderer: human output と `--json` / `--plain`
- 起動画面と入力欄: TTY では color、非TTYでは escape sequence なし、40 桁で表示幅が収まる（観点の一覧は [references/startup-screen.md](references/startup-screen.md) の「テスト」）
- error guidance: `Error:` と `Hint:`、exit code

検証コマンドは README と完了報告に残す。

### 9. Docs

README には次を置く。（出典: [clig: Documentation][clig-docs] の「端末の中でも Web でも引ける、版に合った説明」。項目の並びは取り決め）

- 1 行説明
- setup / dependencies
- typical usage
- examples 3-5 個
- options summary
- machine mode examples
- test command
- known prerequisites / external tools

repo に `AGENTS.md` や tool list がある場合は、同じ変更で更新する。エージェント向けには repo の root に `AGENTS.md`、複雑な workflow は `skills/` に置く。（出典: [Google Cloud Tech][gct]）


## Review Checklist

各項目の根拠は、上の Workflow の対応する行の出典を参照。

- core logic と renderer が分かれている (data と presentation の分離)
- `--help` と `-h` に examples があり、command が機能別に group 化されている
- `--json` / `--plain` / `--no-banner` など machine mode がある
- 非 TTY / CI / `<APP>_NO_TUI` / `--no-input` で非対話 mode になり、`NO_COLOR` / `TERM=dumb` で色が止まる
- stdout と stderr の責務が分かれている
- default output が短く重要順。truncate したら絞り方を示す。secrets が mask されている
- destructive action が明示 flag (`--yes` / `--force`) を要求する。変更を伴う command に `--dry-run` がある
- error に実行可能な `Hint:` があり、重い処理の前に設定・接続を確かめている
- exit code が決定的
- `--version` がある
- 知らない command を既定の command に流さず、exit 2 と近い候補で返す。省略形を受けない
- CLI のディレクトリが repo の型検査・lint の対象に入っている（取り決め: 型検査の外にあって誤りを見逃した実例から。[references/service-client-cli.md](references/service-client-cli.md)）
- `SIGINT` を graceful に扱い、data corruption を起こさない。インストールしたコマンドで Ctrl-C / Ctrl-D を送っても Traceback が出ない
- 起動画面は枠なし・名前のバッジ・1 行の説明・今の状態・ヒント 1 行で、非対話実行では出さない
- 起動画面と入力欄の折り返しが表示幅（全角 2 桁）で数えられ、40 桁で崩れない
- 問いかけが「? 問い  既定 x」と「› 」の 2 行で、文言に「(既定: x)」「(y/n)」を自前で付けていない
- 状態に出す既定値が、引数の定義と同じ定数から取られている
- バッジの名前、help の command、README の名前が一致している
- accent color はユーザー確認または明確なブランド色に基づき、`NO_COLOR` と非 TTY で抑制される
- README と root tool list が更新されている
- テストが外部ネットワークや本物の destructive action に依存しない（取り決め）

## When To Search Docs

次は公式 docs / primary source を確認する。

- uv、Python packaging、CLI framework、Rich、外部 API の使い方が不明
- library の version によって挙動が変わりそう
- `pyproject.toml`、entry points、dependency、lockfile を更新する
- Agent-friendly output や color behavior の根拠を説明したい

参照:
- `references/sources.md`: 出典の一覧と各資料の要点、根拠の種類
- `references/agent-friendly-cli.md`: Agent-friendly CLI の詳細ガイダンス
- `references/argparse-japanese-help.md`: argparse の usage / -h を日本語化するときの罠

[gct]: https://x.com/GoogleCloudTech/status/2038778093104779537
[anthropic]: https://www.anthropic.com/research/writing-tools-for-agents
[poehnelt]: https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/
[clig-basics]: https://clig.dev/#the-basics
[clig-help]: https://clig.dev/#help
[clig-docs]: https://clig.dev/#documentation
[clig-output]: https://clig.dev/#output
[clig-errors]: https://clig.dev/#errors
[clig-args]: https://clig.dev/#arguments-and-flags
[clig-interactive]: https://clig.dev/#interactivity
[clig-sub]: https://clig.dev/#subcommands
[clig-robust]: https://clig.dev/#robustness-guidelines
[clig-signals]: https://clig.dev/#signals
[no-color]: https://no-color.org/
[xdg]: https://specifications.freedesktop.org/basedir/latest/
[ndjson]: https://github.com/ndjson/ndjson-spec
[argparse]: https://docs.python.org/3/library/argparse.html
[gh-exit]: https://cli.github.com/manual/gh_help_exit-codes
[bash-exit]: https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html
[uv]: https://docs.astral.sh/uv/guides/projects/
[pyproject]: https://packaging.python.org/en/latest/guides/writing-pyproject-toml/
