#!/usr/bin/env bash
# worker が作業の完了・ブロックを report ファイルの隣の done マーカーへ記録する。
# worker には通信先(transport / pane ID / route manifest)を一切渡さない。
# 宛先情報を worker に握らせると、codex の automatic approval review が
# 「task ファイル由来の未検証な宛先へ workspace 由来のレポートを送信する」として
# 実行を拒否する(2026-07-17 実測)。そのため worker 側は /tmp への素朴な
# ファイル書き込みだけにし、done マーカーの検知と実際の配送は投函側が
# report_route.sh で起動した courier (deliver_report.sh) が行う。
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: mark_report_done.sh <report-file> <完了|ブロック> <1行要約>" >&2; exit 2; }
report_file="$1"
status="$2"
summary="$3"
[[ "$report_file" == /tmp/* ]] || { echo "error: report-file は /tmp 配下にすること: $report_file" >&2; exit 1; }
[[ -f "$report_file" ]] || { echo "error: 先に report を書くこと: $report_file" >&2; exit 1; }
[[ "$summary" != *$'\n'* ]] || { echo "error: 要約は1行のみ" >&2; exit 1; }
[[ "$status" == "完了" || "$status" == "ブロック" ]] || { echo "error: status は 完了 または ブロック" >&2; exit 2; }

done_file="$report_file.done"
if [[ -e "$done_file" ]]; then
  echo "error: この report は記録済み。同じ report パスで再実行しない: $done_file" >&2
  exit 1
fi

# 部分書き込みを courier に読ませないため、mktemp + mv で atomic に置く
tmp=$(mktemp "$done_file.XXXXXX")
printf 'status=%s\nsummary=%s\n' "$status" "$summary" >"$tmp"
mv "$tmp" "$done_file"
echo "作業ステータスを記録した: $done_file"

# courier が実際に配送できたかを report_file の隣の receipt
# (<report>.delivered / <report>.undeliverable)で待つ。これは worker の
# 1回の tool 呼び出し内に閉じた有界 wait であり、ターンをまたぐポーリング
# (agent-orchestrate で禁止されている待機)ではない。この結果を確認しないまま
# 「報告した/送信した」と worker が言い切ることを防ぐのが目的
# (2026-09-02 実測: courier は送達コマンドに成功していたが着弾は未確認のまま、
# worker が直接の質問に3回連続で「報告済みです」と答えていた)。
delivered_file="$report_file.delivered"
undeliverable_file="$report_file.undeliverable"
for _ in $(seq 1 30); do
  if [[ -f "$delivered_file" ]]; then
    confirmed=$(grep '^confirmed=' "$delivered_file" | cut -d= -f2-)
    if [[ "$confirmed" == "unconfirmed" ]]; then
      echo "warning: 配送コマンドは成功したが着弾を確認できていない。report ファイルの「## 報告配送」節を必ず読み、その内容をそのまま最終報告に反映すること(自分の判断で「送信した」と言い切らない)" >&2
    else
      echo "配送を確認できた ($confirmed)"
    fi
    exit 0
  fi
  if [[ -f "$undeliverable_file" ]]; then
    echo "error: 配送できなかった。report ファイルの「## 報告配送」節を必ず読み、その内容をそのまま最終報告に反映すること" >&2
    exit 1
  fi
  sleep 2
done
echo "warning: 配送状況を60秒待っても確認できなかった(courier が起動していない可能性がある)。「報告した/送信した」とは言わず、配送が未確認であることをそのまま最終報告に書くこと" >&2
exit 1
