# 指定時刻に送る(予約送信)

## GOAL

- 指定した時刻まで待ってから、tmux または Herdr の指定した pane へ送る。
- 送ること自体(transport の選び方、本文と Enter を分けること、着弾の確認)は delivery.md が正本。ここには独自の送信の処理を持たない。

## PRIMARY RULES

- 予約とは、指定した時刻まで待つことと、delivery.md の手順で送ることの 2 つだけ。`send-keys` の細かい手順をここに写さない。
- 宛先は pane ID で固定する(tmux は `%0`、Herdr は `w1:p1`)。「今の pane」のような曖昧な指定は使わない。transport は pane ID の形で決め、推測しない。
- 時刻は絶対時刻に直し、今の時刻と比べて過ぎていないことを確かめてから予約する。
- 予約する前に「どの pane に、いつ、何を送るか」を 1 文で示す。足りない情報は 1 回に 1 問ずつ聞く。

## Workflow

1. 宛先の pane を決める。一覧の取り方は delivery.md の「1. 宛先ペインを確定する」に従い、pane ID に固定する。
2. 時刻を決める。`date '+%Y-%m-%d %H:%M:%S %Z'` で今の時刻を取り、相対の指定は絶対時刻に直して確かめる。待つ秒数は `date -j -f '%Y-%m-%d %H:%M %Z' '<絶対時刻>' +%s` と `date +%s` の差で出す。0 以下なら取りやめる。
3. 待ってから送るコマンドを組み立てる。送る部分には、delivery.md の「3. 送信する」の専用スクリプトをそのまま使う。

   ```bash
   nohup bash -c 'sleep <待ち秒数>; bash <skill-dir>/scripts/<tmux_send.sh|herdr_send.sh> <pane-id> "<1行メッセージ>"' >/tmp/<slug>-schedule.log 2>&1 &
   echo "pid=$!"
   ```

   Enter だけを送るときは、スクリプトの代わりに、delivery.md の「3. 送信する」にある手で送る手順のうち Enter だけの行(tmux は `tmux send-keys -t <pane-id> Enter`、Herdr は `herdr pane send-keys <pane-id> ENTER`)を使う。
4. 予約を入れる(ユーザーが自分で実行したいなら、コマンドだけを返す)。PID とログのパスを伝える。
5. 確かめ方を伝える。`ps -p <PID> -o pid=,etime=,command=` でまだ待っているかを、ログで送った結果を確かめる。送ったあとの着弾の確認は delivery.md の「4. 着弾を確認する」に従う。

## 注意点

- 予約は `nohup` でバックグラウンドに置いた sleep なので、Mac がスリープしている間は進まない。時刻どおりに確実に送りたいときは、スリープさせないようユーザーに伝える。
- 予約したあとで pane が閉じたり別の用途に変わったりすると、違う相手に送ってしまう。時刻の直前に pane の様子が変わっていないかを確かめるよう、ユーザーに促す。
