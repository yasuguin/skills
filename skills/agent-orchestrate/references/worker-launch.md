# worker の起動(詳細)

SKILL.md の Workflow 2 の詳細。自分の pane の確かめ方、会話を再開したあとの注意、起動の設定、Herdr での起動、並行の worktree を持つ。
`<skill-dir>` は、この skill(SKILL.md のあるディレクトリ)の絶対パスを指す。

## 自分の pane を確かめる

```sh
if [[ "${HERDR_ENV:-}" == "1" && -n "${HERDR_PANE_ID:-}" ]]; then
  self="$HERDR_PANE_ID"
  herdr pane get "$self" # Herdr の返信先を検証する
elif [[ -n "${TMUX_PANE:-}" ]]; then
  self="$TMUX_PANE"
  tmux display-message -p -t "$self" '#{pane_id}'
else
  echo "error: tmux でも Herdr でもないセッションでは orchestrator になれない" >&2
  exit 1
fi
echo "reply-to=$self"
```

- **前提チェック**: orchestrator は tmux か Herdr の pane の中で動いている必要がある。どちらでもないと `$TMUX_PANE` が空になり、
  返信先が空の manifest ができて、報告がすべて黙って迷子になる。この分岐に落ちたら worker を起動せずに止まり、
  tmux / Herdr の中でセッションを開き直すようユーザーに頼む。ポーリングや自分での実装に切り替えて代わりにしない。
- Herdr の中では、送り手が名前のない pane でも、**`$HERDR_PANE_ID` が返信先の正本**になる。`herdr pane get "$self"` が成功した値を使い、
  role は補助の情報として扱う。`$TMUX_PANE` は Herdr を包む外側の tmux の pane なので、Herdr の中のエージェント同士の返信先には使わない。
- **会話を再開(compaction)したあとは、自分の pane id を確かめ直す**。Claude Code の Bash から見た `TMUX_PANE` が空になることがある。
  空のまま `tmux split-window -t "$TMUX_PANE"` すると、`-t ""` が別のセッションのアクティブな pane を分割し、worker がユーザーの別の作業のウィンドウに出てしまう
  (出てしまったら `tmux join-pane -h -s <worker> -t <自分>` で戻す)。`report_route.sh` も `TMUX_PANE is not available` で止まる。
  最初の投函で確かめた自分の pane id を控えておき、再開したあとは `tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index} #{pane_title}'` で
  まだ生きているかを確かめてから、分割先と `TMUX_PANE=<自分の pane id> bash report_route.sh ...` に明示する。分からなければ分割しない。

## 起動の設定と Herdr

- worker 専用の起動オプション(`codex -p worker` など)を使うなら、設定ファイル `${AGENT_ORCHESTRATE_WORKERS:-~/.config/agent-orchestrate/workers.sh}` で
  `agent_invocation`(起動コマンドの配列)を `$agent` ごとに差し替える。script がこのファイルを source する。
- Herdr の中では、上のコマンドが同梱の `scripts/herdr_start_agent.sh "$worker_role" -- "$worker_agent" ...` を実行する。
  この script は `herdr agent start` を包んだもので、`herdr` と `jq` が要る。対象 repo の Herdr workspace を使い回し、
  対話の zsh で端末の初期化を済ませてから agent を起動する。起動したら、`herdr agent start` の結果に含まれる `pane_id` を `$worker` として受け取る。
  role 名で探し直すと古い agent の登録を拾うことがあるので、探し直さない。こうして、投函する側とされる側が同じ `<worker-role>` / `wN:pN` を持つ。

## 依存し合わない ticket を並行に起動する

- **依存し合わない ticket は、`git worktree add` で作業ツリーを分けて並行に起動する**。PR は積み重ねにせず、マージの順は orchestrator が決める。
  並行の worker に E2E(実際のサーバーを起動するテスト)を同時に回させない。ファイルが重ならないことは安全の条件にならない。
  dev サーバーは作業ツリー全体を読むので、別の worker の書きかけのコードで、関係のないところが落ちる。E2E は 1 本ずつ回すか、worktree ごとに E2E のポートも分ける
  (worktree を分けても、Playwright の `reuseExistingServer` が固定のポートを取り合い、他の worktree のサーバーに当たる)。
  ポートやローカルの DB がぶつかる repo では task に注意を書き、ぶつかる検証は orchestrator 側でまとめて回す。
