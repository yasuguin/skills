# retro の候補を置き場所へ落とす

`/retro` は環境改善の候補を挙げて止まる。候補を受け取ったら、この表で置き場所を決めてから直す。
retro は `CODING_STANDARDS.md` と「規約を課すレビュー役のエージェント」があることを前提にしている。どちらも無い環境では、規約を下の表の置き場所に分けて置き、レビューは任せる側のエージェントが受け持つ。

| retro のカテゴリ | 置き場所 |
|---|---|
| Navigation | instruction file の参照ガイド（ナビゲーションポインタだけ）、skill の description |
| Automated checks | 対象 repo の lint / typecheck / test・pre-commit・CI |
| Coding standards（mechanical） | hook の禁止パターン、repo の linter のカスタムルール |
| Coding standards（judgement） | その領域の skill の判断基準 |
| Global AGENTS.md | 圧縮し、機械判定できるルールは hook へ移す |
| Tool economy | 重い手順は skill の `scripts/` へ、単純な変換は CLI へ（`cli-creator`） |
| No-ops | instruction file と skill 本文から削除する（skill-kaizen の統合・削除） |
| Information access | エージェントの設定（MCP・permissions）、ログの tee |
| retro の外（環境の罠・過去の判断・好み） | 長期記憶、repo の設計判断はその repo の ADR（`domain-modeling`） |

担当が skill の改善以外の候補は、その置き場所に合う手順で直す。skill-kaizen は表で振り分けたあと、skill の担当分だけを Workflow 2 以降で進める。
