#!/usr/bin/env bash
# orchestrator 向けの任意の追加パス(courier の代替ではない)。
# report_route.sh 実行後、ホスト CLI の「バックグラウンド実行した処理の完了で通知が届き、
# ターンが自動再開される」機能でこれを起動しておくと、report_file.done の出現を
# tmux/herdr へのキー入力を経由せずに知れる。
#
# courier は引き続き必須で起動すること。理由:
# - 並行投函の混戦防止(route manifest による分離)は courier 側の役割
# - 上記の契約を持たないホスト CLI では、courier の [報告] 着弾が唯一の通知経路
# - 依頼主へ実際に配送された記録は courier の receipt が正
# そのためこのスクリプトは「worker 完了を早く知る」冗長パスに限定し、レビューの正本は
# 従来どおり Workflow 6 の courier 系ファイルを使う。
#
# 確認フラグを必須にしている理由: 上記の契約を持たないホストがこのスクリプトをシェルの
# `&` で起動しても完了通知は誰にも届かず、「報告が届き次第」と述べたまま永久に再開しない
# 事故が実際に起きた(2026-09-02)。ホスト CLI の種類は script からは判定できないため、
# 呼び出し側に「自分のツールがその契約を持つと確認した」自己申告を強制する。
[[ "${1:-}" == "--i-confirmed-run-in-background-auto-resumes-my-turn" ]] || {
  cat >&2 <<'EOF'
error: 実行を拒否した。このスクリプトは「起動したバックグラウンド処理が完了すると、
自分のターンが自動的に再開される」という契約が成立するホスト(Claude Code の
run_in_background:true 等)でしか意味を持たない。今使っている Bash 相当ツールの
説明文にその契約が明記されているか確認し、確認できたら第1引数に
`--i-confirmed-run-in-background-auto-resumes-my-turn` を付けて実行すること。
確信が持てない場合はこのスクリプトを使わず、courier の [報告] 着弾だけに頼ること。
EOF
  exit 2
}
shift
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: wait_for_report.sh --i-confirmed-run-in-background-auto-resumes-my-turn <report-file> [max-seconds=28800]" >&2; exit 2; }
report_file="$1"
max_seconds="${2:-28800}"
[[ "$report_file" == /tmp/* ]] || { echo "error: report-file は /tmp 配下にすること: $report_file" >&2; exit 1; }

signal_file="$report_file.done"
elapsed=0
while [[ ! -f "$signal_file" ]]; do
  if (( elapsed >= max_seconds )); then
    echo "timeout: ${max_seconds}秒待っても $signal_file が出現しなかった。courier 経由の [報告] 着弾を確認すること" >&2
    exit 1
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

status=""
summary=""
# mark_report_done.sh は atomic に書くが、フォールバックの printf 直書きは部分書き込みを
# 読みうるので、有効な内容になるまで少しだけ再読する(deliver_report.sh と同じ理由)。
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

# courier の配送結果（receipt）も通知に載せる。done だけを見ると、[報告] が届いていないことに orchestrator が
# 気づけない（2026-10-05 実測: 配送不能の .undeliverable が誰にも読まれなかった）。courier の再試行が終わるまで待つ
delivery="pending"
for _ in $(seq 1 60); do
  if [[ -f "$report_file.undeliverable" ]]; then delivery="undeliverable"; break; fi
  if [[ -f "$report_file.delivered" ]]; then
    confirmed=$(sed -n 's/^confirmed=//p' "$report_file.delivered")
    delivery="delivered"
    [[ "$confirmed" == "unconfirmed" ]] && delivery="unconfirmed"
    break
  fi
  sleep 3
done

echo "worker完了検知: status=$status summary=$summary delivery=$delivery report=$report_file"
if [[ "$delivery" != "delivered" ]]; then
  echo "warning: [報告] の配送が ${delivery}。report を直接読み、配送できなかったことを依頼主へ伝えること"
fi
