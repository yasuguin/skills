# argparse の日本語化の罠

2026-09-16、ある自作 CLI で `usage:` / `options:` / `-h` の説明を日本語にしたときに踏んだ 2 件。どちらも `--help` を実際に出力するまで気づけない。サブコマンドの `--help` まで確かめる。ここに書いたことは、そのとき出力で確かめた実測（根拠の種類は [sources.md](sources.md)）。

## usage が二重になる（prefix の None 判定）

`HelpFormatter.add_usage` を override して `prefix="使い方: "` を無条件に渡すと、サブコマンドの usage が `使い方: 使い方: cli.py aliases ...` になる。

原因は `add_subparsers` が prog を決めるために `formatter.add_usage(self.usage, positionals, groups, '')` を prefix='' で明示的に呼ぶこと。ここまで置換すると prog 自体が `使い方: cli.py` になり、サブパーサの usage 生成時にもう一度 prefix が付く。prefix が None のときだけ差し替える。（実測。原因の説明は CPython の `Lib/argparse.py` の読みで、ソースの行までは確かめていない）

```python
def add_usage(self, usage, actions, groups, prefix=None):
    super().add_usage(usage, actions, groups, "使い方: " if prefix is None else prefix)
```

## 親の usage= がサブコマンドへ漏れる

親パーサに `usage="cli.py <コマンド> [オプション]"` を指定すると、同じく prog がその文字列から作られ、サブコマンドの usage が `使い方: cli.py <コマンド> [オプション] aliases [-h]` になる。親の `usage=` は上書きせず argparse に組ませる。（実測。Python 3.14 からは親の `usage=` がサブパーサの `prog` に影響しなくなった。出典: [argparse][argparse]。3.13 以前で動かすなら引き続き避ける）

## -h / --help の説明文

`add_help=True` で自動追加される `-h` の help は `show this help message and exit` 固定。パーサ生成後に `argparse._HelpAction` の action を探して `action.help` を差し替える。見出しは `parser._optionals.title` / `parser._positionals.title` で変える。（実測。`_HelpAction`・`_optionals` は非公開の属性なので、Python の版を上げたら確かめ直す）

サブコマンド単体の `--help` にも効かせるには `add_subparsers(parser_class=...)` に同じ生成関数を渡す。トップの `--help` だけ見て日本語化できたと判断しない。

## 表の桁揃え

日本語見出しの表を `str.ljust` で揃えると端末上でずれる。`unicodedata.east_asian_width(c) in ("W", "F")` の文字を 2 桁として数える幅計算が要る（文字列の `in "WF"` だと部分文字列の判定になる）。幅の数え方の注意は [startup-screen.md](startup-screen.md) の「幅と折り返し」。（出典: [textwrap][textwrap] は文字数で数える、[UAX #11][uax11]）

[argparse]: https://docs.python.org/3/library/argparse.html
[textwrap]: https://docs.python.org/3/library/textwrap.html
[uax11]: https://www.unicode.org/reports/tr11/
