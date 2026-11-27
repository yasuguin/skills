# pane への送信（delivery）

pane への送信の正本。タスク投函・完了報告・予約送信・通知のすべてがここの手順を使う。
`<skill-dir>` は、この skill（SKILL.md のあるディレクトリ）の絶対パス。

## GOAL

tmux または Herdr の指定 pane へ 1 行メッセージを確実に届ける(打ち込み → 送信確定 → 着弾確認)。

## PRIMARY RULES

- メッセージは **1 行のみ**。改行を含む長文は送らない。長い内容は `/tmp/<slug>-*.md` 等のファイルに書き、メッセージにはファイルパスと一行要約だけを載せる。
- 宛先は **pane ID で固定**する。tmux は `%0` 形式、Herdr は `w1:p1` 形式を使う。「右のペイン」「アクティブペイン」のような曖昧指定のまま送らない。
- Herdr では送る前に `herdr pane get <pane-id>` で宛先を確認する。名前なし pane に role を推測してはならない。投函側が確認した `origin=wN:pN` と `reply-to=wN:pN` を task と報告へ残す。
- **Herdr 内の起動元へ返送するときは、投函側が `HERDR_PANE_ID` から実値を固定した `reply-to` を宛先にする。** worker の `$HERDR_PANE_ID` は worker 自身の ID であり、起動元の代用にはならない。`$TMUX_PANE` は外側 tmux の pane ID であり、Herdr 内の返信先には使わない。Herdr 管理外では従来どおり `$TMUX_PANE` を使う。
- 本文の打ち込みと Enter は**別コマンドに分ける**(間に 1 秒)。TUI の補完ポップアップや IME が Enter を横取りするのを避けるため。
- Herdr の `send-keys` で本文を確定するときは、キー名を大文字の **`ENTER`** にする。小文字の `enter` は本文を確定しない。
- 本文は `-l`(literal)で送る。`send-keys` は `Enter` や `Space` などの単語をキー名として解釈するため、`-l` なしだと本文が壊れることがある。
- tmux は `tmux send-keys` が成功した時点を**tmux への送達確認**とする。`capture-pane` は診断用に残すが、TUI が受理した入力を消す場合があるため、本文の不在を未送信の根拠にしない。tmux では画面表示だけを理由に Enter・本文を安易に再送しない。**限定例外(起動直後の飲み込み)**: 相手 agent が起動・再描画中に本文が丸ごと落ちることがある(codex の起動バナー表示中の投函が 2 回連続で消失した実測)。送信後に相手が実行中表示へ遷移せず、かつ入力欄が**空(プレースホルダー表示)** のときだけ、ENTER 再送 1 回 → 本文再送 1 回の順で復旧してよい(空の入力欄への本文再送は二重投函にならない。入力欄に本文が残っている場合は ENTER のみ)。task の end-to-end 完了は、SKILL.md の報告配送（courier）で確認する。
- Herdr は送信後に本文と状態を確認する。本文が見えるだけでは入力欄に未送信で残ったケースを区別できないため、送信先が送信前に `idle` の Herdr agent なら、**`working` への遷移も送信完了条件**とする。確認に失敗したときは、**本文を再送せず ENTER だけを 1 回だけ再送**する。本文の再送は、最初の Enter だけが落ちた場合に同じ task を二重投函するため禁止する。
- 相手のエージェントが処理中でも入力はキューされるので、待たずに送ってよい。
- 相手 TUI が**ターン終了直後の再描画中だと入力が丸ごと落ちる**ことがある(実測)。Herdr の同梱スクリプトは着弾と、idle agent なら処理開始状態を検証し、確認できなければ ENTER だけを 1 回自動再送する。tmux は共通の受理状態を取得できないので、`send-keys` の成功を送達確認とし、後続の報告着弾で end-to-end を確認する。手動で送る場合も送信後の `capture-pane` を診断として確認する。

## Workflow

### 1. 宛先ペインを確定する

- 指示でペイン ID が渡されていればそれを最優先で使う。
- なければ一覧から探す。自分のペイン(`$TMUX_PANE`)は宛先候補から除外する。

```sh
tmux list-panes -a -F 'pane_id=#{pane_id} cmd=#{pane_current_command} title=#{pane_title}'
herdr pane list # Herdr 内ではこちらの pane_id (w1:p1 形式) を確認する
herdr agent get reviewer # 登録済み agent の確認用。この skill は起動結果の pane_id を使い、role 名から再検索しない
```

- `cmd=codex` / `cmd=claude` など `pane_current_command` で相手エージェントを特定する。候補が複数あって絞れない場合はユーザーに確認する。

### 2. メッセージを整形する

- 1 行・要点のみ。タスク投函と報告は次のテンプレに従う。

タスク投函(orchestrator → worker):

```
/tmp/<slug>-task.md を読んで、その指示どおり作業してください。完了・ブロック時の報告手順もそのファイルにあります。
```

完了・ブロック報告(worker → orchestrator):

```
[報告] <タスク名> 完了: <一行要約>。詳細: /tmp/<slug>-report.md
[報告] <タスク名> ブロック: <理由の一行要約>。詳細: /tmp/<slug>-report.md
```

Herdr の報告では両者の対応を残す:

```
[報告] <タスク名> 完了 orchestrator=orchestrator/w1:p1 worker=<worker-role>/w2:p1: <一行要約>。詳細: /tmp/<slug>-report.md
```

### 3. 送信する

transport を自動推測せず、task の `transport` と一致する専用スクリプトを使う。両方とも異なる ID 形式を受け付けず、
外側 tmux と Herdr の混同を即時に失敗させる:

```sh
bash <skill-dir>/scripts/herdr_send.sh <wN:pN> '<1行メッセージ>'
bash <skill-dir>/scripts/tmux_send.sh <%NN> '<1行メッセージ>'
```

スクリプトが使えない環境では同じ手順を手で行う:

```sh
tmux send-keys -t <pane_id> -l -- '<1行メッセージ>'
sleep 1
tmux send-keys -t <pane_id> Enter
```

Herdr で手動送信する場合:

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

- tmux は `tmux_send.sh` が正常終了すれば、tmux server が本文と Enter を対象 pane へ受け付けたことを確認できて成功。capture に本文がなくても直ちには再送しない。相手が実行中表示へ遷移せず入力欄が空のままの場合のみ、上記の限定例外(ENTER 1 回 → 本文 1 回)で復旧する。
- Herdr で送信前に `idle` だった agent は、本文表示に加えて `herdr pane get <pane-id>` の `agent_status=working` を確認できて成功。
  Herdr の出力は表示幅で折り返されるため、同梱スクリプトは空白を除いて本文を照合する。入力欄に本文が**未確定のまま**残っている、または idle agent が `working` へ遷移しない場合は、ENTER を 1 回だけ再送する。
  本文は再送しない。それでも確認できなければ送信失敗としてユーザーに報告する(連打しない)。

- 指定時刻まで待ってから送りたい(予約送信)ときは [schedule.md](schedule.md) を読む(時刻の確定と待ち方。送信手順はこの本文に従う)。
