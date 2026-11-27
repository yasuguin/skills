# 起動画面と入力欄

SKILL.md の Workflow 5 から参照される。対話起動する CLI で、人が最初に見る画面（起動画面）と、続く問いかけ（入力欄）の作り方。

既定は「スマホの SSH（縦持ちで 40 桁前後）でも崩れず、すぐ入力に入れる」こと。大きなブロックアートのロゴ、罫線の枠、長い使い方の一覧は出さない。6 行のロゴと 8 行の説明は、狭い画面では入力欄を画面の外へ押し出し、日本語の折り返しで枠も崩すため。

このファイルの見た目と入力欄の決まりは、外部の出典ではなく取り決め（2026-11-25、手元の 21 ツールの起動画面を作り直したときに、スマホで見比べて決めた）。外部の出典があるものだけ、その行に出典を付ける（一覧は [sources.md](sources.md)）。

同じ repo に複数のツールがあるときは、起動画面と問いかけを 1 箇所の共通部品（`render_banner` / `print_banner` / `ask` / `confirm` など）にまとめ、各ツールで複製しない。


## 起動画面

```text
 youtube-dl  v0.6.1                 ← 名前はアクセント色の背景のバッジ、版は薄い色
YouTube の動画・プレイリストを保存   ← 何をするかを 1 行
                                     ← 状態があるときだけ 1 行空ける
出力  ~/Downloads/youtube-dl         ← 今の状態。ラベルは薄い色、2 文字に揃える
画質  1080p
--help で全オプション · ^C で終了    ← 薄い色のヒント 1 行
```

- **枠を引かない。** 左右の罫線（`│`・`▎`・`╭─╮`）は、日本語の幅のずれや画面幅の変化（スマホの回転・tmux の分割）で崩れ、見た目も重い。どこからが起動画面かは、名前のバッジで示す。階層は色より余白と位置で作る。（出典: [Google Cloud Tech][gct] の「whitespace over color」）
- **名前のバッジ**: 前景色のアクセント色（`38;2;R;G;B` / `38;5;N`）を背景色（`48;…`）に読み替え、文字は暗色・太字にする。色を出さないときは名前だけを出す。名前と版が 1 行に入らない幅では版を省く。
- **載せるのは「今の状態」**: 出力先、既定の画質・形式など、実行したら何がどうなるかを `(ラベル, 値)` で 1〜3 行。値は定数や出力先を決める関数から取り、引数の定義と二重に書かない（ずれると、画面と実際の既定値が食い違う）。ホーム配下のパスは `~` に縮める。既定値が無く起動後に選ぶ項目は載せない。
- **使い方の一覧は出さない**: `--json` / `--plain` / サブコマンドの案内は `--help` に任せ、ヒント 1 行で入口を示すだけにする。（出典: [clig: Help][clig-help] の「既定では短い help を出し、詳しくは `--help` へ」）
- **説明は 40 桁で 1 行**: 全角 19 文字前後まで。長い説明は README と `--help` に書く。

## 幅と折り返し

- 幅は `shutil.get_terminal_size((80, 24)).columns` と上限（56 桁）の小さい方。罫線を引かないので、幅は折り返しにしか使わない。（出典: [shutil.get_terminal_size][shutil] は `COLUMNS`・端末・fallback の順に幅を決める。56 桁は取り決め）
- **表示幅で数える。** `textwrap.wrap` は文字数で数えるので、日本語の行は 2 倍にあふれる（40 桁の画面で 1 行が 74 桁になる）。`unicodedata.east_asian_width(ch) in ("W", "F")` を 2 桁、結合文字を 0 桁として数え、自前で折り返す。（出典: [textwrap][textwrap] は文字数で数える、[unicodedata][unicodedata]、[UAX #11][uax11]）
- この数え方は近似。UAX #11 は端末での利用を意図しておらず（§2）、Ambiguous（A: ギリシャ文字・罫線・一部の記号）は端末の設定で 1 桁にも 2 桁にもなる。絵文字や ZWJ でつないだ絵文字も端末ごとに幅が違う。起動画面や問いかけの文言には、A の文字と絵文字を入れない。（出典: [UAX #11][uax11] §2・§5・§6.2）
- 英単語は途中で切らない。パスは `/` の直後で折り返す（`~/Downloads/` と `image-list-downloader` に分ける）。1 語が幅を超えるときだけ語の途中で切る。
- 状態の値が折り返すときは、ラベルの幅だけ字下げして続ける。

## 入力欄

```text
? 解像度（DPI）  既定 300           ← ? はアクセント色、「既定 x」は薄い色
›                                    ← 入力行。› のあとに空白 1 つ
                                     ← 答えのあとに 1 行空ける
? この内容で変換しますか？  y/N
› n
```

- 問いかけの行と `› ` の入力行の 2 行に分ける。スマホでも入力行を幅いっぱいに使え、続けて聞いたときにどこまで答えたかを追いやすい。
- 問いの文言に「: 」「を入力してください」「(既定: x)」「[x]」「(空 Enter で x)」「(y/n)」を付けない。既定値の表示と y/n の表示は部品側が出す。
- **既定値**: 空 Enter でその値を使うなら `default` に渡す（空 Enter で `str(default)` が返る）。空 Enter を「ツール側で自動に決める」（None 扱い）意味のまま残したいときは、表示専用の `default_label` で行き先を見せ、戻り値は空文字のままにする。`default` に表示用のパスを渡すと、戻り値の型や意味が変わる。
- **必須**: 空なら「入力が空です」と出して同じ問いを出し直す。
- **パス**: ドラッグ&ドロップで付く前後の引用符を外す（`strip_quotes`）。
- **y/n**: 空 Enter は既定（大文字の側。`Y/n` なら「はい」）。y/yes/はい・n/no/いいえ を受け付け、それ以外は聞き直す。確認が「中止」を既定にしていた箇所は `default=False` にする。
- 問いかけの直後に出す見出し（`--- 設定内容 ---` など）の先頭に改行を付けない。入力欄が答えのあとに 1 行空けるので、2 行空きになる。
- 問いかけは入力欄と同じ stdout に出す（`input()` のプロンプトは stdout に書かれる。出典: [input][input]）。stderr しか受け取らない関数（実行環境の確認など）から聞くときも、問いかけだけは stdout へ向ける。
- 矢印キーの選択 UI（questionary、自作 TUI など）は別物として残してよい。`input()` で聞く箇所だけを揃える。

## 色と出す条件

- 色は出力先が TTY で、`NO_COLOR` が未設定（または空）のときだけ付ける。（出典: [NO_COLOR][no-color]、[clig: Output][clig-output]）`--plain` / `--json` / 非 TTY / `CI` では起動画面そのものを出さない。問いかけは stdin が TTY のときだけ出す。（出典: [clig: Interactivity][clig-interactive]。`CI` を条件に入れるのは経験則）
- 色を付けるのはバッジ・`?`・`›` のアクセント色と、補足の薄い色（`\033[2m`）だけ。本文は端末の既定色のまま。
- 入力行のプロンプトに ANSI を含めるので、`readline` を import する CLI ではカーソル位置がずれる。readline を使うなら ANSI を `\001` / `\002` で囲む。（出典: [GNU Readline: Redisplay][readline] の `RL_PROMPT_START_IGNORE` / `RL_PROMPT_END_IGNORE`、[input][input] は readline が読み込まれていれば使う）
- URL や必須引数が渡された非対話の実行では起動画面を出さない。必要なら短い実行サマリにする。（出典: [clig: Output][clig-output] の「成功時の出力は短く」）

## テスト

- 起動画面: 40 桁でどの行も表示幅が収まる、狭い幅で版を省く、色なしで ANSI が出ない、TTY で背景色のバッジが出る。
- 入力欄: 問いと `› ` の 2 行と空行、空 Enter で `default`、`default_label` は空文字を返す、必須の聞き直し、y/n の既定と聞き直し。`input_func` を注入し、渡されたプロンプトと output を確かめる。
- 複数ツールを持つ repo では、全ツールの説明が 40 桁に収まり、ラベルが 2 文字かを 1 本のテストで確かめる。

[gct]: https://x.com/GoogleCloudTech/status/2038778093104779537
[clig-help]: https://clig.dev/#help
[clig-output]: https://clig.dev/#output
[clig-interactive]: https://clig.dev/#interactivity
[no-color]: https://no-color.org/
[shutil]: https://docs.python.org/3/library/shutil.html#shutil.get_terminal_size
[textwrap]: https://docs.python.org/3/library/textwrap.html
[unicodedata]: https://docs.python.org/3/library/unicodedata.html
[uax11]: https://www.unicode.org/reports/tr11/
[input]: https://docs.python.org/3/library/functions.html#input
[readline]: https://tiswww.case.edu/php/chet/readline/readline.html#Redisplay
