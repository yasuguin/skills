#!/usr/bin/env bash
# worker エージェントを新規起動し、pane_id だけを stdout に返す。
# 履歴を持たない worker に依頼するため、既存ペインは使い回さない。
# Herdr 内では Herdr の agent として起動し、tmux では従来どおり pane を起動する。
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ $# -lt 3 ]]; then
  echo "usage: ensure_worker_pane.sh <agent-command(codex|claude|pi)> <workdir> <worker-role>" >&2
  exit 2
fi

agent="$1"
workdir="$2"
worker_role="$3"

case "$agent" in
  codex|claude|pi) ;;
  *)
    echo "error: 未対応の agent: $agent (codex|claude|pi から選ぶこと)" >&2
    exit 2
    ;;
esac

# agent ごとに起動完了後の通常入力待ちを示す画面上のマーカーを持つ(hook 未導入でも
# 画面スクレイピングだけで判定できるようにするため)。テーマ選択・フォルダ信頼確認などの
# 初回ダイアログはこれらのマーカーを出さないので、そのまま待機タイムアウトへ落ちて
# 「未知のダイアログ・承認待ちを自動で迂回しない」という既定の挙動になる。
# - codex: 入力欄の `›` プロンプト
# - claude: 通常 REPL 下部のステータス行 (`Ctx:` を含む)。トラスト確認ダイアログの
#   選択肢にも `❯` は出るが `Ctx:` は出ないため、これで判別できる。
# - pi: 画面下部のステータス行にある `(auto)`(コンテキスト使用率表示)。作業中は
#   同じ行がスピナー付き `Working` 表示に切り替わるため誤判定しない
ready_marker() {
  case "$agent" in
    codex) printf '%s' '›' ;;
    claude) printf '%s' 'Ctx:' ;;
    pi) printf '%s' '(auto)' ;;
  esac
}

# worker はどの agent でも通常の承認・sandbox 設定のまま起動する。起動ラッパーが
# 安全機構を無効化すると、orchestrator 側の auto mode に拒否されるためである。
# 役割は task ファイルの役割宣言で渡すので、既定では agent をそのまま起動する。
# worker 専用の起動オプションを使うときは、ここを差し替える。
case "$agent" in
  codex|claude|pi) agent_invocation=("$agent") ;;
esac
# worker 専用の起動オプションは、設定ファイルが agent_invocation を差し替えて表す。
workers_config="${AGENT_ORCHESTRATE_WORKERS:-$HOME/.config/agent-orchestrate/workers.sh}"
if [[ -f "$workers_config" ]]; then
  # shellcheck source=/dev/null
  source "$workers_config"
fi

if [[ "${HERDR_ENV:-}" == "1" && -n "${HERDR_PANE_ID:-}" ]]; then
  # 起動結果は専用ファイルに書く。role 名の再検索は同名の古い登録を拾うので使わない。
  start_result=$(mktemp /tmp/agent-orchestrate-start.XXXXXX)
  trap 'rm -f "$start_result"' EXIT
  (cd -- "$workdir" && bash "$script_dir/herdr_start_agent.sh" "$worker_role" -- "${agent_invocation[@]}" >"$start_result")
  worker=$(jq -er '.result.agent.pane_id' <"$start_result")
  herdr pane get "$worker" >/dev/null

  # pane 作成直後は agent_status=idle でも TUI がまだ入力を受け付けない。
  # この段階で task を送ると本文は後から処理される一方、送信側の着弾確認は失敗する。
  # 各 agent は起動完了後に自身の準備完了マーカーを表示して idle になるので、その両方を確認してから返す。
  marker=$(ready_marker)
  for _ in $(seq 1 60); do
    screen=$(herdr pane read "$worker" --source recent-unwrapped --lines 30 2>/dev/null || true)
    if [[ "$(herdr pane get "$worker" | jq -r '.result.pane.agent_status // "unknown"')" =~ ^(idle|done)$ \
      && "$screen" == *"$marker"* ]]; then
      echo "info: $agent の起動完了を確認した: $worker" >&2
      break
    fi
    sleep 1
  done
  [[ "$(herdr pane get "$worker" | jq -r '.result.pane.agent_status // "unknown"')" =~ ^(idle|done)$ \
    && "${screen:-}" == *"$marker"* ]] || {
    echo "error: $agent の起動完了を60秒以内に確認できなかった(pane=$worker)。未知の初回ダイアログや承認待ちの可能性があるため、pane を確認すること。" >&2
    exit 1
  }
  echo "info: Herdr agent '$worker_role' を新規起動した: $worker" >&2
  echo "$worker"
  exit 0
fi

# シェル経由で起動する(直接 command 指定だと zsh rc を経由せず mise の PATH が効かないため)。
# worker は orchestrator と同じウィンドウに置く(ユーザーが作業の様子を見られるようにするため。
# 別ウィンドウや break-pane で隠さない)。手狭で分割に失敗したら、
# ウィンドウ全体を均等に並べ直してから分割し直す。それでも入らなければ別ウィンドウへ逃がさず止める。
new_pane=$(tmux split-window -h -P -F '#{pane_id}' -c "$workdir" 2>/dev/null) || {
  tmux select-layout tiled >/dev/null
  new_pane=$(tmux split-window -P -F '#{pane_id}' -c "$workdir") || {
    echo "error: orchestrator のウィンドウに worker の pane を追加できなかった。ウィンドウを広げるか、終わった worker の pane を閉じてから再実行すること。" >&2
    exit 1
  }
}
# split-window は分割元の pane を半分にするだけなので、worker を続けて起動すると
# 先に起動した pane の幅が 1 桁まで縮み、pi の TUI が「Rendered line exceeds terminal width」
# で異常終了した (2026-09-17 実測)。分割のたびにウィンドウ全体を均等に並べ直す。
tmux select-layout -t "$new_pane" tiled >/dev/null
sleep 1
tmux send-keys -t "$new_pane" -l -- "${agent_invocation[*]}"
sleep 1
tmux send-keys -t "$new_pane" Enter

# 起動完了を最大 30 秒待つ(これは起動の同期であって、タスク完了のポーリングではない)。
# pane_current_command はシェル shim 経由で起動する agent (実測で "sh" のまま
# 変化しない)では信頼できないため使わず、Herdr 経路と同じ画面マーカー方式に統一する。
marker=$(ready_marker)
for _ in $(seq 1 30); do
  snap=$(tmux capture-pane -p -t "$new_pane" 2>/dev/null || true)
  if [[ "$snap" == *"$marker"* ]]; then
    echo "info: $agent を新規セッションで起動した: $new_pane" >&2
    echo "$new_pane"
    exit 0
  fi
  sleep 1
done

echo "error: $agent が 30 秒以内に起動しなかった(pane=$new_pane)。ペインの状態を確認すること。" >&2
echo "$new_pane"
exit 1
