# 困ったときの切り分け

報告が届かない、worker が止まった、起動しないときに読む。ふだんの手順は SKILL.md の Workflow にある。

## 報告が届かない

- pi を含め、worker の最終回答を pane の間で中継する機能には頼らない。pi のふだんの最終回答は pi の pane の中にしか出ない。
  起動元の pane に届くのは、courier が打ち込む `[報告]` 行だけ。
- 起動元の pane に報告が見当たらないときは、worker の返事を待ち直したり pane から書き写したりしない。
  route manifest の `report_file` と、その `.done`・`.delivered`・`.undeliverable`、それに `route_file.courier.log` を読む。
  - `.done` が無い: worker は報告の処理まで終えていない。`tmux capture-pane -p -t <worker>`(Herdr は `herdr pane read`)で 1 回だけ様子を見る。
  - receipt が `confirmed=unconfirmed`: 送るコマンドは成功していて、着弾を確かめられなかっただけ。report を読んで Workflow 6 へ進む。
    tmux では、どの TUI にも使える確認手段が `tmux send-keys` の受理までしかないので、courier は送る前と後で宛先の pane の表示が変わったかを
    着弾の追加の根拠にしている(相手が処理を始めれば、TUI の種類に関係なく何かが変わる)。変わらなかったときにこの receipt になる。
    Herdr では `herdr_send.sh` の着弾と処理開始の確認をそのまま使う。
  - `.undeliverable` か courier の log にエラーがある: 配送の失敗として扱う。宛先を推測して送り直さない。
- `[報告]` 行は起動元の pane へのキー入力なので、orchestrator を動かしている CLI が会話のイベントとして取り込むとは限らない。
  見えないことだけで異常とは判断しない。
- 宛先の pane が途中で消えて配送できないのは、実装上の `ブロック` ではない。配送と、配送できなかった記録は courier(`deliver_report.sh`)が行う。
  `mark_report_done.sh` は done マーカーを書いたあと、courier の receipt を最大 60 秒待ってから終わる(受け取れなければ 0 以外で終わる)。
  同じ report のパスで再実行すると「記録済み」のエラー(exit 1)になるので、タイムアウトしたあとでもマーカーは作り直せない。
- receipt(`<report>.delivered` / `.undeliverable`)は、他の pane からもやりとりの状況を追えるように消さない。
  courier の log と、report 末尾の「報告配送」節に、失敗したときの起動元の pane の状態が残る。

## worker が承認待ちで止まった

- codex や claude は、それぞれの plan の手順に沿って、「実装の前の設計の承認」を pane の中の対話で求めて止まることがある。
  task-template の「対話承認の禁止」節がその先回りの対策なので、agent の種類に関係なく必ず残す。
- それでも止まった場合に限り、orchestrator が同じ pane へ 1 回だけ承認か裁定を送って再開させる
  (止まった worker の再開であって、新しい task の追加の投函ではない)。ユーザーには回さない。

## worker が tmux / herdr を叩けない

- codex の sandbox は(`workspace-write` でも)unix socket への接続を遮るので、tmux も herdr も直接叩くと EPERM になる。
  claude や pi の既定の sandbox でも同じく遮られるものとして扱う。
- 一方、ホストの `/tmp` はどの sandbox からも読み書きできる。報告を done マーカー経由(`mark_report_done.sh`)にしているのはこのため。

## worker が起動しない

- `ensure_worker_pane.sh` は、準備完了マーカーを確かめられないとタイムアウトしてエラーで終わる。初回のダイアログか承認待ちで止まっている
  かもしれない。自動で回避せず、pane を見てユーザーに対応を相談する(ダイアログの扱いは SKILL.md の Workflow 2)。
- 1 つの window で pi を 3 台以上続けて起動すると、3 台目以降の pane の幅が 10 桁ほどに縮み、準備完了マーカー `(auto)` が画面に収まらず、
  30 秒で「起動しなかった」になる(pi 自体は起動している。2026-09-14 実測)。
  `tmux select-layout -t <session:window> tiled` で全部の pane を同じ大きさにしてから、`capture-pane` で `(auto)` を見直す。
  5 台並べても、pane が 69x16 あれば動いた。
