# skills

[English](README.md) | 日本語

[![skills.sh](https://skills.sh/b/yasuguin/skills)](https://skills.sh/yasuguin/skills)

AI エージェント（主に Claude Code）と毎日開発するなかで育てた skill です。どれも、困ったことを 1 つずつ機械で解決してきた結果を、ほかの人の環境でも動く形にしたものです。

skill の本文は日本語で書いています。

## Install

```bash
npx skills@latest add yasuguin/skills
```

1 つだけ入れるときは `--skill` で選べます。

```bash
npx skills@latest add yasuguin/skills --skill grill-visual
```

## Skills

- **[agent-doctor](skills/agent-doctor)**: AI エージェント（Claude Code・Codex）の開発環境を 3 つの面から診断し、問題を生んでいるルールの場所まで辿って、承認したものだけ直します。主役はルールの最適化です。instruction file や skill に文章で書いたルールを棚卸しし、settings・hook・agent 定義・Codex の rules と profile・lint・test の機械的な強制へ移し、重複を削り、書いてあることと実際の強制のずれを直します。速度の診断は、会話ログと hook の実測から開発が遅い原因を見つけます。コストの診断は、利用を API の定価に換算し、料金を押し上げているもの（サブエージェントの型・project・セッション・キャッシュ読み）を見つけます。Python（`uv`）が要ります。週 1 回の自動集計まで欲しいときは、skill を同梱した [agent-doctor の plugin](plugins/agent-doctor) を代わりに入れてください（両方入れると skill が 2 つになります）。
- **[agent-orchestrate](skills/agent-orchestrate)**: tmux（または Herdr）の pane で動く codex・claude・pi に実装を任せ、完了報告のレビューと再依頼を繰り返してゴールまで進めます。pane へ確実に届ける送り方（Enter の分離・着弾の確認・時刻指定の送信）も持っています。
- **[ask-me](skills/ask-me)**: エージェントが聞きたいことを長い文章にまとめて返してきたとき、その問いを 1 論点 1 問の質問カードに分け直させます。全部を読んで答えを組み立てる手間をなくし、選ぶだけで答えられるようにするためのものです。
- **[ban-rule-manager](skills/ban-rule-manager)**: 「〜は使わない」という決まりを文章で頼まず、Claude Code の PreToolUse hook で止めます。禁止の内容は JSON の registry に書くだけで、hook のエンジンは同梱しています。hook を入れる前のコードや、ほかのエージェントが書いたコードを遡ってスキャンする script も付いています。`jq` と `perl` が要ります。
- **[cli-creator](skills/cli-creator)**: CLI を作る・直すときに、command の構成・`--help` の例・`--json`・失敗のヒントと終了コード・テストまでを、エージェントにも人にも使いやすい形にそろえます。
- **[code-as-spec](skills/code-as-spec)**: 仕様書を正本にせず、コード・テスト・型・コードの近くの why コメントを正本にして開発します。spec docs の追従の手間をなくしたいときの考え方と手順です。
- **[grill-visual](skills/grill-visual)**: 質問を詰めていく途中で「読むより見た方が早い」問い（mockup・レイアウトの比較・ナビゲーションの構成・状態遷移図）が出たとき、localhost のブラウザに案を並べて、クリックで選んでもらいます。選んだ結果・案への補足・要素へのコメント・スライダーでの微調整が、そのままエージェントへの指示文になります。Node の標準機能だけで動き、外部へのリクエストはしません。
- **[just-ask](skills/just-ask)**: 編集せずに読むだけで答えるモード。「まず調査だけ」「まだ作業しないで」と言ったときに、実測で裏を取って短く答えます。
- **[skill-kaizen](skills/skill-kaizen)**: 会話の中のフィードバックや繰り返しの修正から、既存の skill を磨くべきタイミングを見つけて直します。継ぎ足すだけでなく、重複や古い記述を削るところまで見ます。
- **[test-human-walkthrough](skills/test-human-walkthrough)**: 架空のユーザーになって、Web アプリ（claude-in-chrome）や macOS のアプリを一操作ずつ触り、気になる点を根拠と証拠付きで報告する探索的テストです。

## Plugins（Claude Code の hook）

hook は Claude Code の plugin として配っています。入れるだけで hook が登録され、要らなくなったら plugin ごと外せます。

```text
/plugin marketplace add yasuguin/skills
/plugin install safety-guard@yasuguin
```

- **[agent-doctor](plugins/agent-doctor)**: agent-doctor の skill に、週 1 回の自動集計を足したものです。
- **[gcloud-readonly](plugins/gcloud-readonly)**: 読み取りだけと判定できた `gcloud` コマンドを確認なしで通します。
- **[orphan-reaper](plugins/orphan-reaper)**: 終わったセッションが置き去りにした dev server やテストのワーカーを片付け、CPU を使い続けている孤児を知らせます。
- **[push-guard](plugins/push-guard)**: 既定ブランチへの `git push` と `gh` での書き込みを、許可リストにある自分の repo だけ確認なしで通します。fork で他人の公開 repo に issue を作ってしまう事故を防ぎます。
- **[safety-guard](plugins/safety-guard)**: 危ないコマンド（`rm -rf`・破壊的な `git checkout`・作業ブランチ以外の削除）を確認に回し、`~/.ssh` の鍵や `.env` の読み出しを止めます。commit メッセージや grep の検索語に書いただけの語では止まりません。
- **[zundamon-notify](plugins/zundamon-notify)**: 完了と入力待ちを VOICEVOX のずんだもんの声で知らせます。

plugin の中の hook は 1 本ずつ外せないので、用途ごとに分けています。

## 謝辞

いくつかの skill は、[mattpocock/skills](https://github.com/mattpocock/skills)（Matt Pocock さん）と [anthropics/skills](https://github.com/anthropics/skills) の skill を名前で呼びます。何を呼ぶかと入れ方は、各 SKILL.md の「前提にしている skill」に書いています。とくに grill-visual と ask-me は、1 問ずつ推奨を添えて詰めていく `grilling` の進め方があったからこそ、小さな形にできました。

## License

[MIT](LICENSE)
