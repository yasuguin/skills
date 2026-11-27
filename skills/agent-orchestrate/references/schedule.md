# 指定時刻に送る(予約送信)

## GOAL

- 指定時刻まで待ってから、tmux または Herdr の指定 pane へ送信する。
- 送信そのもの(transport 選択、本文と Enter の分離、着弾確認)は delivery.md が正本。ここでは独自の送信処理を持たない。

## PRIMARY RULES

- 予約 = 指定時刻まで待つ + delivery.md の手順で送る、だけ。`send-keys` の細部をここに複製しない。
- 宛先は pane ID で固定する(tmux は `%0`、Herdr は `w1:p1`)。「現在の pane」のような曖昧指定は使わない。transport は pane ID の形式で決め、推測しない。
- 時刻は絶対時刻に直し、現在時刻と比べて過去でないことを確認してから予約する。
- 予約する前に「どの pane に、いつ、何を送るか」を一文で示す。不足情報は 1 回 1 問で聞く。

## Workflow

1. 宛先 pane を確定する。一覧の取り方は delivery.md の「1. 宛先ペインを確定する」に従い、pane ID に固定する。
2. 時刻を確定する。`date '+%Y-%m-%d %H:%M:%S %Z'` で現在時刻を取り、相対指定は絶対時刻に直して確認する。待ち秒数は `date -j -f '%Y-%m-%d %H:%M %Z' '<絶対時刻>' +%s` と `date +%s` の差で求める。0 以下なら中止する。
3. 待ってから送るコマンドを作る。送信部分は delivery.md の「3. 送信する」の専用スクリプトをそのまま使う。

   ```bash
   nohup bash -c 'sleep <待ち秒数>; bash <skill-dir>/scripts/<tmux_send.sh|herdr_send.sh> <pane-id> "<1行メッセージ>"' >/tmp/<slug>-schedule.log 2>&1 &
   echo "pid=$!"
   ```

   Enter だけを送るときは、スクリプトの代わりに delivery.md の「手で送る」手順のうち Enter 単独の行(tmux は `tmux send-keys -t <pane-id> Enter`、Herdr は `herdr pane send-keys <pane-id> ENTER`)を使う。
4. 予約を投入する(ユーザーが自分で実行したいならコマンドだけ返す)。PID とログパスを伝える。
5. 確認方法を伝える。`ps -p <PID> -o pid=,etime=,command=` で待機中か、ログで送信結果を確認する。送信後の着弾確認は delivery.md の「4. 着弾を確認する」に従う。

## 注意点

- 予約は `nohup` のバックグラウンド sleep で、Mac のスリープ中は進まない。時刻に確実に送りたいときは、スリープさせないようユーザーに伝える。
- 予約後に pane が閉じる・別の用途に変わると、誤った相手に送る。時刻直前に pane の状態が変わっていないか、ユーザーに確認を促す。
