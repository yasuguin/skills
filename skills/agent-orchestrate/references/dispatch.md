# 投函の前後の確認(詳細)

SKILL.md の Workflow 2 の末尾と Workflow 4 の詳細。worker が入力を受け付けるかの確認、初回起動の信頼ダイアログ、
投函したあとに処理が始まったかの確認、バックグラウンドの完了通知を持つ。送ること自体は pane-send skill が正本。
`<skill-dir>` は、この skill(SKILL.md のあるディレクトリ)の絶対パスを指す。

## 投函の前: 入力を受け付けるか

- **投函の前に、worker が入力を受け付ける状態かを確かめる**。`ensure_worker_pane.sh` は agent ごとの準備完了マーカーを確かめてから worker の ID を返す
  (codex: 入力欄の `›` プロンプト、claude: ステータス行の `Ctx:`、pi: ステータス行の `(auto)`)。マーカーを確かめられなければタイムアウトしてエラーで終わるので、
  自動で回避せず、pane を見てユーザーに対応を相談する。起動直後の `idle` だけを根拠に task を送らない。tmux では念のため、**投函の直前にも until ループでもう一度確かめる**
  (1 回の capture では足りない。起動バナーが出ている間に投函すると丸ごと飲まれる)。

```sh
for i in $(seq 1 30); do
  snap=$(tmux capture-pane -p -t "$worker")
  if grep -qE "loading|Initializing|MCP startup" <<<"$snap"; then sleep 2; continue; fi
  grep -qE "›|Ctx:|Ask anything|\(auto\)" <<<"$snap" && break   # agent ごとの入力プロンプト
  sleep 2
done
```

## 初回起動の信頼ダイアログ

- **その repo で初めて起動したときは、信頼の確認ダイアログを片付けてから投函する**。準備完了マーカーはダイアログの間は出ないので、tmux でも Herdr でも待ちのタイムアウトに落ちる。
  task を送る前に `tmux capture-pane -p -t "$worker" | tail -15`(Herdr では `herdr pane read`)でダイアログが出ていないかを見る。
  前回出なかったから今回も出ない、とは考えず毎回見る。
  - claude: 「フォルダを信頼するか」の 1 段。orchestrator が 1 回だけ `Enter`(既定で選ばれている「1. Yes, I trust this folder」)を送る。
  - codex: 「ディレクトリの信頼」と「hooks の信頼」の 2 段。`Enter` 1 回では 2 段目で止まったままになり、そこへ task を投函すると本文が丸ごと吸い込まれて、
    worker は何もせずに終わる。`›` プロンプトが出るまで確かめながら、**残っている段の数だけ**答える
    (同じ repo の codex をすでに起動していれば出ない。1 段目で `ensure_worker_pane.sh` の判定が通り、出会わないこともある)。

  これは初回起動の環境の確認で、task の実行中の設計の承認とは別物なので、同じ pane への 1 回きりの介入として扱ってよい。

## 投函のあと: 処理が始まったか

- **task の投函は、worker が処理を始めたのを確かめるまでを完了とする**。送るだけで止めると、入力欄に残ったままの task や、起動直後の再描画で飲まれた本文を見逃す。
  - Herdr: 送る前に `idle` だったなら、`herdr_send.sh` の成功出力だけで完了とせず、`herdr pane get "$worker"` で `agent_status=working` に変わったことを確かめる。
    変わらなければ `herdr_send.sh` が Enter だけを 1 回送り直す。
  - tmux: `tmux_send.sh` が正常に終わっても、tmux server が受け付けたことしか分からない。送ったあと、`tmux capture-pane` で `Working` や `esc to interrupt` のような
    実行中の表示に変わるのを最大 20 秒待つ。変わらなければ ENTER を 1 回だけ送り直す。それでも変わらず、入力欄が**空**(プレースホルダーが出ている)なら、
    本文が丸ごと落ちたので、本文を 1 回だけ送り直してよい(空の入力欄へ送り直しても二重の投函にならない。入力欄に本文が残っているなら ENTER だけを送り直す)。
  - それでも確かめられなければ投函の失敗として止まり、「worker に任せた」とは報告しない。

## バックグラウンドの完了通知(追加で使ってよい経路)

- **追加で使ってよい経路**: ホストの CLI の Bash 相当のツールが、「バックグラウンドで実行した処理が終わると通知が届き、ターンが自動で再開する」ことを
  **ツール自身の説明文に明記している**場合に限り、投函と同じターンで
  `bash <skill-dir>/scripts/wait_for_report.sh --i-confirmed-run-in-background-auto-resumes-my-turn /tmp/<slug>-report.md`
  をその機能で起動しておける(例: Claude Code の Bash tool の `run_in_background: true`)。これで `report_file.done` が現れたことを、キー入力なしで知れる。
  - 通知には `worker完了検知: status=... summary=... delivery=... report=<path>` が入る。並行の投函や修正のラウンドが重なっていても、どの task の完了かは `report=` のパスで見分ける(推測で決めない)。
  - この機能があると確かめられないなら使わない。シェルの `&` では代わりにならず、通知は来ない(script が確認のフラグを必須にしているのはこのため)。
  - 使っても courier は省かない。並行の投函を混ぜないこと、この機能を持たないホストへの経路、配送の記録(receipt)は courier の役目のまま。
