---
name: pane-send
description: "tmux または Herdr の pane で動くエージェント(codex / claude / pi など)へ、1 行のメッセージを確実に届ける。transport の選び方、本文と Enter を分けて送ること、着弾の確かめ方、決まった時刻に送る予約送信を持つ。「ペインに送って」「codex に報告して」「Claude に完了を伝えて」「4 時に codex に Enter を送って」のような依頼で使う。worker に実装を任せてレビューを繰り返すのは agent-orchestrate。"
---

# pane-send

pane への送信の正本。agent-orchestrate の task の投函と完了の報告(courier)も、このスクリプトで送る。

`<skill-dir>` は、この skill(SKILL.md のあるディレクトリ)の絶対パスを指す。

## GOAL

tmux または Herdr の指定した pane へ、1 行のメッセージを確実に届ける(打ち込む → 送信を確定する → 着弾を確かめる)。

## PRIMARY RULES

- メッセージは **1 行だけ**。改行を含む長い文は送らない。長い内容は `/tmp/<slug>-*.md` などのファイルに書き、メッセージにはファイルのパスと 1 行の要約だけを載せる。
- 宛先は **pane ID で固定する**。tmux は `%0` の形、Herdr は `w1:p1` の形を使う。「右のペイン」「アクティブなペイン」のような曖昧な指定のまま送らない。
- Herdr では、送る前に `herdr pane get <pane-id>` で宛先を確かめる。名前のない pane の role を推測しない。
  agent-orchestrate の投函では、送り元(`origin` / `reply_to`)は `report_route.sh` が route manifest に固定し、`[報告]` 行には courier が書き込む。task には書かない。
- **Herdr の中の起動元へ返すときは、投函する側が `HERDR_PANE_ID` から値を固定した `reply_to` を宛先にする。** worker の `$HERDR_PANE_ID` は worker 自身の ID なので、起動元の代わりにはならない。
  `$TMUX_PANE` は外側の tmux の pane ID なので、Herdr の中の返信先には使わない。Herdr の外では、これまでどおり `$TMUX_PANE` を使う。
- 本文の打ち込みと Enter は**別のコマンドに分ける**(間を 1 秒あける)。TUI の補完のポップアップや IME に Enter を横取りされないようにするため。
- Herdr の `send-keys` で本文を確定するときは、キー名を大文字の **`ENTER`** にする。小文字の `enter` では本文が確定しない。
- 本文は `-l`(literal)で送る。`send-keys` は `Enter` や `Space` のような単語をキー名として読むので、`-l` を付けないと本文が壊れることがある。
- tmux では、`tmux send-keys` が成功した時点を**tmux への送達の確認**とする。`capture-pane` は診断用に残すが、TUI は受け取った入力を画面から消すことがあるので、
  本文が見えないことを未送信の根拠にしない。tmux では、画面の見た目だけを理由に Enter や本文を気軽に送り直さない。
  **例外は起動直後の飲み込みだけ**: 相手の agent が起動中や再描画中だと、本文が丸ごと落ちることがある(codex の起動バナーが出ている間の投函が 2 回続けて消えた実測がある)。
  送ったあとで相手が実行中の表示に変わらず、しかも入力欄が**空**(プレースホルダーが出ている)のときだけ、ENTER を 1 回送り直し、それでもだめなら本文を 1 回送り直して立て直してよい
  (空の入力欄へ本文を送り直しても二重の投函にならない。入力欄に本文が残っているなら ENTER だけ)。
  task の投函ではさらに、実行中の表示に変わるのを確かめるまでを完了条件にする(agent-orchestrate の Workflow 4)。task が端から端まで通ったかは、agent-orchestrate の報告の配送(courier)で確かめる。
- Herdr では、送ったあとに本文と状態を確かめる。本文が見えるだけでは、入力欄に送られないまま残っている場合と見分けられない。送る前に `idle` だった Herdr の agent なら、
  **`working` に変わることも送信の完了条件**にする。確かめられなかったら、**本文は送り直さず、ENTER だけを 1 回送り直す**。
  最初の Enter だけが落ちていた場合に本文を送り直すと、同じ task を二重に投函してしまうので、本文の再送はしない。
- 相手のエージェントが処理中でも、入力は順番待ちに入るので、待たずに送ってよい。
- 相手の TUI がターンを終えた直後の再描画中だと、**入力が丸ごと落ちる**ことがある(実測)。Herdr の同梱スクリプトは着弾と、idle の agent なら処理が始まったことを確かめ、
  確かめられなければ ENTER だけを 1 回自動で送り直す。tmux には共通に受理の状態を取る方法がないので、`send-keys` の成功を送達の確認とし、端から端まで通ったかはあとで報告が届くことで確かめる。
  手で送る場合も、送ったあとに `capture-pane` で様子を見て診断する。

## Workflow

### 1. 宛先ペインを確定する

- 指示で pane ID を渡されていれば、それをいちばんに使う。
- 無ければ一覧から探す。自分の pane(`$TMUX_PANE`)は宛先の候補から外す。

```sh
tmux list-panes -a -F 'pane_id=#{pane_id} cmd=#{pane_current_command} title=#{pane_title}'
herdr pane list # Herdr 内ではこちらの pane_id (w1:p1 形式) を確認する
herdr agent get reviewer # 登録済み agent の確認用。agent-orchestrate は起動結果の pane_id を使い、role 名から再検索しない
```

- `cmd=codex` / `cmd=claude` のような `pane_current_command` で相手のエージェントを見分ける。候補が複数あって絞れなければユーザーに確かめる。

### 2. メッセージを整形する

- 1 行で、要点だけ。task の投函は次の形にする。

task の投函(orchestrator → worker):

```
/tmp/<slug>-task.md を読んで、その指示どおり作業してください。完了・ブロック時の報告手順もそのファイルにあります。
```

完了・ブロックの報告は、courier(`deliver_report.sh`)が route manifest と done マーカーから組み立てて orchestrator へ送る。worker にも orchestrator にも手で書かせない。
届く形は次のとおり(tmux。Herdr では `worker=<worker-role>/w2:p1` になる)。

```
[報告] <task-id> 完了 origin=%4 worker=%0: <一行要約>。詳細: /tmp/<slug>-report.md
[報告] <task-id> ブロック origin=%4 worker=%0: <理由の一行要約>。詳細: /tmp/<slug>-report.md
```

courier を使わない単発の報告(「codex に報告して」のように、route manifest の無い pane へ手で送る場合)も同じ形にそろえる。
`origin=` には報告を受け取る pane、`worker=` には送る自分の pane(Herdr では `<role>/<pane-id>`)を入れ、両者の対応を残す。

```
[報告] <タスク名> 完了 origin=w1:p1 worker=reviewer/w2:p1: <一行要約>。詳細: /tmp/<slug>-report.md
```

### 3. 送信する

transport を推測で決めず、route manifest の `transport`(manifest が無い単発の送信では宛先の pane ID の形)に合う専用スクリプトを使う。
どちらのスクリプトも違う形の ID を受け付けないので、外側の tmux と Herdr を取り違えるとすぐに失敗する。

```sh
bash <skill-dir>/scripts/herdr_send.sh <wN:pN> '<1行メッセージ>'
bash <skill-dir>/scripts/tmux_send.sh <%NN> '<1行メッセージ>'
```

スクリプトを使えない環境では、同じ手順を手で行う。

```sh
tmux send-keys -t <pane_id> -l -- '<1行メッセージ>'
sleep 1
tmux send-keys -t <pane_id> Enter
```

Herdr で手で送る場合:

```sh
herdr pane send-text <herdr-pane-id> '<1行メッセージ>'
sleep 1
herdr pane send-keys <herdr-pane-id> ENTER
```

### 4. 着弾を確認する

```sh
tmux capture-pane -p -t <tmux-pane-id> | tail -15
herdr pane read <herdr-pane-id> --source recent-unwrapped --lines 15
```

- tmux では、`tmux_send.sh` が正常に終われば、tmux server が本文と Enter を宛先の pane へ受け付けたことになり、成功とする。capture に本文が無くても、すぐには送り直さない。
  相手が実行中の表示に変わらず、入力欄が空のままの場合に限り、上の例外(ENTER を 1 回 → 本文を 1 回)で立て直す。
- Herdr で、送る前に `idle` だった agent は、本文が表示され、さらに `herdr pane get <pane-id>` で `agent_status=working` を確かめられたら成功とする。
  Herdr の出力は表示の幅で折り返されるので、同梱スクリプトは空白を除いて本文を照らし合わせる。入力欄に本文が**確定されないまま**残っている、
  または idle の agent が `working` に変わらない場合は、ENTER を 1 回だけ送り直す。
  本文は送り直さない。それでも確かめられなければ、送信の失敗としてユーザーに報告する(何度も送らない)。

- 決まった時刻まで待ってから送りたい(予約送信)ときは [references/schedule.md](references/schedule.md) を読む(時刻の決め方と待ち方。送る手順はこのファイルに従う)。
