# AGENTS

この repo の中身は、正本の場所が 2 通りある。

- **この repo が正本**: 版の管理（`package.json`・`pnpm-lock.yaml`・`.changeset/`・`CHANGELOG.md`・`.github/`・`scripts/`・`.gitignore`）と、`skills/` のうち `grill-visual`・`agent-orchestrate`・`pane-send`・`skill-kaizen`・`cli-creator`・`code-as-spec`・`just-ask`・`ask-me`・`test-human-walkthrough`、`tests/`、この `AGENTS.md`。ここで直して PR で入れる。
- **別の repo から書き出しているもの**: 上以外のすべて（ほかの `skills/`、`plugins/`、`.claude-plugin/`、`README.md`、`README.ja.md`、`LICENSE`）。次の書き出しで丸ごと上書きされるので、ここでは編集しない。

## 変更の入れ方

PR で入れ、changeset を 1 つ付ける（`pnpm changeset`）。上げ幅は、skill の追加・振る舞いの変化が minor、文言や不具合の直しが patch、skill の削除・改名が major。

## テスト

```bash
pnpm install && pnpm run check-frontmatter
bun test tests/grill-visual
for t in skills/agent-orchestrate/tests/*.sh skills/pane-send/tests/*.sh; do bash "$t"; done   # 一部は tmux の中で回す
```

## 書き方

- skill の本文は日本語で書く。
- 特定の人の環境（ホームのパス、個人の repo 名、ほかで公開していない skill）に触れない。環境ごとの違いは、使う側が後から足せる形（設定・環境変数・追記）にする。
