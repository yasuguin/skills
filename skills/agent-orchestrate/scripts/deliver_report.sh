#!/usr/bin/env bash
# 報告配送の courier。投函側(非 sandbox)が report_route.sh から起動する。
# worker に配送させない理由は 2 つ:
# - codex sandbox は unix socket への connect を遮断する(tmux/herdr とも EPERM)
# - 宛先情報(manifest)を worker に渡すと codex の approval review が exfiltration と
#   判定して報告コマンド自体を拒否する(2026-07-17 実測)
# そのため worker は report と done マーカー(<report>.done = manifest の signal_file)を
# 書くだけにし、socket への配送はこの courier が代行する。
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: deliver_report.sh <route-file>" >&2; exit 2; }
route_file="$1"
[[ "$route_file" == /tmp/* && -f "$route_file" ]] || { echo "error: route-file が見つからない: $route_file" >&2; exit 1; }

# Keep the courier compatible with macOS /bin/bash 3.2 as well as WSL Bash 5.
# In particular, Bash 3.2 has no associative arrays; a parse error here prevents
# the courier from ever returning the worker report to its origin pane.
schema=""
task_id=""
transport=""
origin=""
worker_role=""
worker_pane=""
reply_to=""
report_file=""
signal_file=""
while IFS='=' read -r key value; do
  [[ -n "$key" ]] || continue
  case "$key" in
    schema) schema="$value" ;;
    task_id) task_id="$value" ;;
    transport) transport="$value" ;;
    origin) origin="$value" ;;
    worker_role) worker_role="$value" ;;
    worker_pane) worker_pane="$value" ;;
    reply_to) reply_to="$value" ;;
    report_file) report_file="$value" ;;
    signal_file) signal_file="$value" ;;
  esac
done <"$route_file"
[[ -n "$schema" && -n "$task_id" && -n "$transport" && -n "$origin" && -n "$worker_role" && -n "$worker_pane" && -n "$reply_to" && -n "$report_file" && -n "$signal_file" ]] || { echo "error: route manifest に必須項目がない" >&2; exit 1; }
[[ "$schema" == "agent-orchestrate-route-v1" ]] || { echo "error: 未対応の route manifest" >&2; exit 1; }
[[ "$signal_file" == /tmp/* ]] || { echo "error: signal_file は /tmp 配下にすること" >&2; exit 1; }

# テストでは未デプロイの sender を差し替えられるようにする
sender_dir="${AGENTS_PLAY_CATCH_SENDER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# signal の着弾を最大 8 時間待つ。route が消えたら投函側が片付けたとみなして黙って終了する。
# これは orchestrator エージェントのターン内ポーリングではなく、detach した shell プロセスの待機。
for _ in $(seq 1 14400); do
  [[ -f "$route_file" ]] || exit 0
  [[ -f "$signal_file" ]] && break
  sleep 2
done
[[ -f "$signal_file" ]] || exit 0

status=""
summary=""
# mark_report_done.sh は atomic に書くが、worker が printf 直書きへフォールバックした
# 場合は部分書き込みを読みうるので、有効な内容になるまで少しだけ再読する
for _ in $(seq 1 10); do
  status=""
  summary=""
  while IFS='=' read -r key value; do
    case "$key" in
      status) status="$value" ;;
      summary) summary="$value" ;;
    esac
  done <"$signal_file"
  [[ -n "$status" && -n "$summary" ]] && break
  sleep 1
done
[[ -n "$status" && -n "$summary" ]] || { echo "error: signal file が不正: $signal_file" >&2; exit 1; }

record_delivery_unavailable() {
  local detail="$1"
  {
    printf '\n## 報告配送\n\n'
    printf '完了・ブロックの作業報告を `%s` へ送信したが、再試行しても配送できなかった。\n' "$reply_to"
    printf '通信経路は manifest の正本から変更・推測せず、別の宛先への送信や `ブロック` としての送信は行わない。\n'
    printf '送信エラー: `%s`\n' "$detail"
  } >>"$report_file"
  echo "warning: 報告先へ配送できなかったため、詳細を report_file に記録して終了します: $detail" >&2
}

if [[ "$transport" == "herdr" ]]; then
  [[ "$origin" =~ ^[^[:space:]:]+:p[^[:space:]:]+$ && "$worker_pane" =~ ^[^[:space:]:]+:p[^[:space:]:]+$ && "$reply_to" == "$origin" ]] || { echo "error: Herdr route が不正" >&2; exit 1; }
  msg="[報告] ${task_id} ${status} origin=${origin} worker=${worker_role}/${worker_pane}: ${summary}。詳細: ${report_file}"
  send=(bash "$sender_dir/herdr_send.sh" "$reply_to" "$msg")
elif [[ "$transport" == "tmux" ]]; then
  [[ "$origin" == %* && "$worker_pane" == %* && "$reply_to" == "$origin" ]] || { echo "error: tmux route が不正" >&2; exit 1; }
  msg="[報告] ${task_id} ${status} origin=${origin} worker=${worker_pane}: ${summary}。詳細: ${report_file}"
  send=(bash "$sender_dir/tmux_send.sh" "$reply_to" "$msg")
  # 着弾確認は特定 TUI の表示文言に依存させない(2026-09-02 実測: 当初 `Working|esc to interrupt`
  # で判定したが、Claude Code 系のスピナー表示(処理中を示す記号+動詞)はこの語にマッチせず、
  # 実際には着弾していた配送を「未確認」と誤判定するバグになっていた)。送信前後で pane の
  # 表示内容が変化したかどうかで判定する: 相手が新しいメッセージを受け取って処理を始めれば
  # (スピナー・ステータス行・出力のいずれであれ)画面は何かしら変化するため、agent の種類を問わない。
  pre_snap=$(tmux capture-pane -p -t "$origin" 2>/dev/null || true)
else
  echo "error: 未対応 transport: $transport" >&2
  exit 1
fi

# 送信は一時的に失敗しうる（2026-10-05 実測: 起動元 pane へ tmux が「not in a mode」を返し、1 回の失敗で
# .undeliverable になって [報告] が届かなかった）。同じ宛先へ間隔を空けて数回送り直す。宛先は manifest の正本の
# まま変えない。途中まで入力されてから失敗した場合は [報告] が 2 行届きうるが、届かないより害が小さい。
retry_interval="${AGENTS_PLAY_CATCH_RETRY_INTERVAL_SECONDS:-20}"
delivery_output=""
delivered_by_command=""
for attempt in 1 2 3 4 5 6; do
  if delivery_output=$("${send[@]}" 2>&1); then
    delivered_by_command="yes"
    break
  fi
  echo "warning: 報告の送信に失敗（${attempt} 回目）: $delivery_output" >&2
  (( attempt < 6 )) && sleep "$retry_interval"
done
if [[ -z "$delivered_by_command" ]]; then
  # 失敗の原因を次に調べられるよう、最後の失敗時の起動元 pane の状態を残す
  if [[ "$transport" == "tmux" ]]; then
    pane_state=$(tmux display-message -p -t "$origin" 'pane_in_mode=#{pane_in_mode} pane_mode=#{pane_mode} pane_dead=#{pane_dead}' 2>&1 || true)
    delivery_output="${delivery_output}（6 回試行。最後の失敗時の起動元 pane: ${pane_state}）"
  fi
  record_delivery_unavailable "$delivery_output"
  printf 'status=undeliverable\n' >"$report_file.undeliverable"
  exit 0
fi
printf '%s\n' "$delivery_output"

write_delivered() {
  printf 'confirmed=%s\ndelivered_at=%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$report_file.delivered"
}

if [[ "$transport" == "herdr" ]]; then
  # herdr_send.sh は送信内で着弾(landed)と処理開始(submitted)を確認済み
  # (確認できなければ非0で終了してここには来ない)なので、その確認をそのまま採用する。
  write_delivered "herdr-landing-check"
  exit 0
fi

# tmux は send-keys の受理までしか汎用に確認できない(references/delivery.md 参照)。
# `tmux send-keys` 成功後も、TUI の再描画中に本文が丸ごと飲み込まれて実際には
# 着弾しないことがある。送信直前に取った pre_snap と比較し、pane の表示内容が
# 変化したかどうかを着弾の追加根拠として最大20秒待つ(相手が新しいメッセージを
# 受け取って処理を始めれば、スピナー・ステータス行・出力のいずれかで画面は必ず
# 変化するため、agent の種類ごとの表示文言を知らなくても判定できる)。
# 確認できなくても送達コマンド自体は成功しているため配送失敗扱いにはしないが、
# 着弾未確認である旨を report_file と receipt に残し、待ち受け側(mark_report_done.sh)
# が「報告した」と言い切らせないようにする。
confirmed=""
for _ in $(seq 1 10); do
  sleep 2
  snap=$(tmux capture-pane -p -t "$origin" 2>/dev/null || true)
  if [[ "$snap" != "$pre_snap" ]]; then
    confirmed="tmux-pane-changed"
    break
  fi
done
if [[ -n "$confirmed" ]]; then
  write_delivered "$confirmed"
else
  write_delivered "unconfirmed"
  {
    printf '\n## 報告配送\n\n'
    printf '`%s` へ送信コマンドは成功したが、実行中表示への遷移を確認できず着弾は未確認。\n' "$reply_to"
    printf 'origin pane を直接確認すること。\n'
  } >>"$report_file"
fi
