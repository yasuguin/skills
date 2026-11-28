# レビューの手順(詳細)

SKILL.md の Workflow 6 の詳細。報告と投函の照合、worker の pane の閉じ方、証拠の退避、残ったプロセスの停止、検証の記録を採用する条件を持つ。

## 報告を照らし合わせ、worker の pane を閉じる

- **報告がどのやりとりのものかを照らし合わせ、worker の pane を閉じる**。
  - `[報告]` 行で気づいた場合: その行、route manifest、report ファイルを読む。manifest の `task_id`・`worker_pane`・`report_file` と合わない報告は、別のやりとりのものとして扱い、worker を閉じない。
    Herdr 宛ての報告は `herdr_send.sh` が Herdr の pane へ直接入力するので、外側の tmux の pane の scrollback ではなく、この会話に届いたものを正とする。
    `worker=<role>/<pane-id>` が今回投函した worker と一致し、report ファイルを読めたら閉じる。自分の pane と一致する場合、報告に pane id が無い場合、まだ report を読めていない場合は閉じない。
  - `wait_for_report.sh` の通知で気づいた場合: `$worker`(Workflow 2 で確保した pane ID)をそのまま使って閉じてよい。通知の `delivery=` が `delivered` 以外
    (`undeliverable`・`unconfirmed`・`pending`)なら `[報告]` は届いていないので、ユーザーへの報告に「この worker の `[報告]` は配送できなかった」と書く。
  - Workflow 5 のディスク上の確認で気づいた場合: `$worker` をそのまま使って閉じてよい。閉じても作業ツリーの diff は残るので、続くレビューの手順を必ずやり切る。

```sh
reported_worker='<[報告] 行の worker=<worker-role>/wN:pN または worker=%NN から pane ID を転記>'
worker="${worker:-$reported_worker}"
if [[ "${HERDR_ENV:-}" == "1" && -n "${HERDR_PANE_ID:-}" ]]; then
  [[ "$worker" != "$HERDR_PANE_ID" ]] && herdr pane close "$worker"
elif [[ -n "${worker:-}" && "$worker" != "${TMUX_PANE:-}" ]]; then
  tmux kill-pane -t "$worker" || true
fi
```

## 証拠を退避する

- **報告を読んだら、まず証拠を退避する**。`/tmp` はセッションの区切りやモデルの切り替えで丸ごと消えることがあり、report と検証のログが消えると裏取りの根拠がなくなる。
  次のラウンドの worker が「読むべき計画ファイルが無い」でブロックしたり、裏取りができずに全量を回し直したりすることにもなる。
  worker の書き込み先は sandbox の制約があるので `/tmp` のままにし、届いた直後に orchestrator が退避する。

```sh
slug=<slug>
keep=~/.local/state/agent-orchestrate/"$slug"
mkdir -p "$keep" && cp -f /tmp/"$slug"*-report.md /tmp/"$slug"*.log /tmp/"$slug"-task.md "$keep"/ 2>/dev/null
```

  長い調査の計画のように、複数のラウンドで参照する成果物も同じ場所に退避し、以後は退避先を参照する。

## worker が残したプロセスを止める

- **worker が起動したまま残したプロセスを止める**。worker が dev server や workerd を止め忘れ、ポート(例: 5173)を握ったまま pane を閉じることがある。
  実機で確かめる前に `lsof -nP -iTCP:<port> -sTCP:LISTEN` で持ち主を確かめ、今回の worker が起動したものなら止める。task にも「撮影のあとで dev server を止める」と書く。

## 検証の記録を採用する条件と、回し直す場合

- 検証の記録を確かめる。変更が触った層に応じて、repo の検証コマンド(repo の AGENTS.md などに書かれた typecheck・test・lint など)の成功の記録を見る。
  重い repo では、重い段を orchestrator がここで実行する。記録を採用する条件は次の 4 つ。
  1. 記録にコマンドと真の exit code がある
  2. 対応するログファイルが実在し、末尾がその task の正常な完了のまとめ(テストの集計、build の完了行など)と食い違わない
  3. 記録の時刻が、この往復の作業時間と合う
  4. 記録のあとで検証の入力が変わっていない(レビュー中の diff の精読は入力を変えない)
- **回し直すのは次の場合だけ**: 成功の記録が無い、記録とログが食い違う、ログが途中で切れている、レビューでコードに手を入れた、
  実行順や環境によるフレークを疑う具体的な根拠がある。回し直すときはまず該当する 1 task に絞り、全量を回し直すのは実際に食い違いが見つかったときだけにする。
  worker が task ファイルの名指しで一部の suite だけを回していた場合も、その report を成功の根拠にせず、ここで検証コマンドの記録を確かめる。
  worker が「既存の失敗」「環境の問題」と書いてきたら、修正前の commit で同じ失敗が出たログが無い限り差し戻す。
- **合否は真の exit code で決める**。`cmd | grep 'fail' | ...` のようなパイプで要約すると、exit code がパイプで差し替わる。
  そのうえ、テストランナーの外で起きた失敗(script の中の `cd` の失敗、ランナー自体の異常終了)はパターンに現れず、「全部緑」に見える。
  `cmd > log 2>&1; echo exit=$?` で先に exit code を確定し、ログの grep は内訳をつかむためにだけ使う。
