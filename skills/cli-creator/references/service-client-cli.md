# サービスの API を叩く CLI（MCP・HTTP API と並ぶ入口）

自前のサービスに CLI・MCP・HTTP API など複数の入口があり、CLI がその 1 つになるときの作り方。起動画面や対話は要らず、利用者の中心はエージェントとパイプになる。このファイルの大半は、作者が自前のサービスの CLI を作り直したとき（2026-11-11）に決めた取り決め。外部の出典があるものだけ出典を付ける（一覧は [sources.md](sources.md)）。

## 入口の揃え方

- **操作の対応表を 1 つ置く**。CLI の command・MCP の tool・API の route を 1 行ずつ並べたファイル（例: `operations.ts`）を正本にし、テストで 3 つとの一致を確かめる。CLI 側は command の一覧と表、サーバー側は MCP の `tools/list` と表を比べる。操作を足すときは表に 1 行足して全部の入口に同時に実装する。（出典: [Poehnelt][poehnelt] の「全部の入口を 1 つの正本から作る」。表をテストで固定するのは作者の取り決め）
- **わざと揃えない操作は表に書く**（全件の書き出しは CLI だけ、など）。黙って欠けている入口と区別できるようにする。
- **CLI が呼ぶ route がサーバーの許可表に入っているかをテストする**。トークンで入る入口が許可表（allowlist）で route を絞るとき、fake fetch に残った method と path を許可表の判定関数に通す。片方だけ直すと、本番で初めて 404 になる。（取り決め: 作者が踏んだ失敗から）

## 層の分け方

- **client（engine）**: API を呼び、型付きの値を返すか、失敗の値を投げる。表示を持たない（例: `client.ts`）。（出典: [Google Cloud Tech][gct] の data と presentation の分離）
- **command の殻**: `--help`・引数の解析・環境変数の確認・失敗の出し方を全 command で共通にする（例: `command.ts` の `runCommand`）。各 command は「client を呼んで描く」だけになる。
- **入口（dispatcher）**: command 名の表から引く。**知らない名前を既定の command（push など）に流さない**。流すと `--version` や打ち間違いが既定の command の使い方を出して終わり、原因が分からない。（出典: [clig: Subcommands][clig-sub] の「catch-all の subcommand を作らない」）

## 失敗の形

失敗は 1 つの型（code・message・hint・exitCode・requestId）にまとめ、出口を 1 か所にする。

- stderr に `エラー: …（code=…, requestId=…）` と `ヒント: …` の 2 行（作者の既存 CLI の表示。新しく作るなら見出しは英語の `Error:` / `Hint:`。SKILL.md の手順 6）。ヒントは次の一手（どこで何を発行して何に登録するか、どの command で ID を確かめるか）。（出典: [clig: Errors][clig-errors]、[Google Cloud Tech][gct]）
- `--json` のときは、成功だけでなく失敗も全 command で stdout に `{"error":{…}}` を出す。command ごとに形を変えない。（取り決め: エージェントが stdout の 1 本だけで成功も失敗も読めるようにするため。[clig: The Basics][clig-basics] はエラーを stderr に出すよう勧めるが、`--json` のときだけ意図して外す。2026-11-25 に維持を決めた）
- 終了コードを、エージェントが次の行動を決められる粒度で分ける: 0 成功・1 操作の失敗（NOT_FOUND・CONFLICT）・2 使い方の誤り・3 認証・権限・接続・環境変数の不足（設定を直せば通る。エージェントは自分で直さず人に伝える）。読むだけのトークンで書こうとした 403 も 3。（出典: [Google Cloud Tech][gct] の 0/1/2/3。403 を 3 に入れるのは作者の取り決め。値の割り当ては CLI ごとに割れている（[gh][gh-exit] は 4 = 要認証）ので、README に書く）
- サーバーの Problem Details の `code` からヒントと終了コードを引く表を 1 つ持つ。`code` は RFC 9457 の標準のメンバー（type・status・title・detail・instance）ではなく、サーバーが足す拡張メンバー。（出典: [RFC 9457 §3.2][rfc9457]）

## command の揃え方

- 一般的な CLI の動詞を揃える（出典: [clig: Subcommands][clig-sub] の「subcommand の間で揃える」。動詞の選び方は作者の取り決め）: search / get / push（作成・置き換え）/ update / delete / files / cat / revisions / restore / links / tags / export、サブリソースは `<子リソース> list|get|set|append|versions|restore` のようにまとめる。
- 削除の確認: 元に戻せる削除（ゴミ箱へ移す）は `--yes` を求めず、skill 側で「頼まれたときだけ、ID と題名を確かめてから」にする。完全削除を足すなら `--yes` を必須にする。（出典: [clig: Arguments and flags][clig-args] の危険度の段階）
- 楽観ロックのある書き込み（version を渡す子リソースなど）は、CLI が今の version を読んでから書く。衝突は exit 1 とヒント（読み直す command）で返す。
- 旧版への復元は、専用 API が無ければ「旧版を読んで置き換えとして保管し直す」を CLI 側で組む。新しい API を足さずに済む。

## テストで固定すること

- 全 command に `--help` があり、例（`例:`）が付いている。（出典: [clig: Help][clig-help]、[Google Cloud Tech][gct]）
- `--version` の値が package.json（pyproject）の version と一致する。
- 知らない command は exit 2。（出典: [argparse][argparse] の使い方の誤りは 2）
- 失敗の分類（終了コードとヒントの有無）。
- **CLI のディレクトリが型検査の対象に入っている**。CLI のディレクトリがどの tsconfig にも含まれていないと、変数の消し忘れが lint も型検査も素通りする（作者が踏んだ失敗）。

## 認証の移行

- トークンを旧方式（例: 既存のサービストークン）から新方式（アプリで発行する API トークン）へ替えるとき、CLI が利用者の手元へ自動で配られているなら、デプロイとトークン発行が済むまで旧方式も受ける。新方式で本番の読み書きを確かめたら、旧方式の経路は消す。
- 主体（どのトークンで操作したか）はサーバーが認証から決め、リクエスト本文の申告で上書きさせない。（出典: [Poehnelt][poehnelt] の「エージェントは信頼できる操作者ではない」。認証の移行手順は作者の取り決め）

[gct]: https://x.com/GoogleCloudTech/status/2038778093104779537
[poehnelt]: https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/
[clig-basics]: https://clig.dev/#the-basics
[clig-help]: https://clig.dev/#help
[clig-errors]: https://clig.dev/#errors
[clig-args]: https://clig.dev/#arguments-and-flags
[clig-sub]: https://clig.dev/#subcommands
[rfc9457]: https://www.rfc-editor.org/rfc/rfc9457.html#section-3.2
[gh-exit]: https://cli.github.com/manual/gh_help_exit-codes
[argparse]: https://docs.python.org/3/library/argparse.html
