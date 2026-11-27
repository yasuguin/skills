#!/usr/bin/env bash
# check_delivery.sh の必須テスト・lint 抑制・lint 設定変更の照合を確認する。
set -euo pipefail

source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$source_dir/scripts/check_delivery.sh"
test_dir=$(mktemp -d /tmp/agent-orchestrate-check-delivery.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
repo="$test_dir/repo"
mkdir -p "$repo/tests"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf '%s\n' 'const value = 1;' > "$repo/src.ts"
git -C "$repo" add .
git -C "$repo" commit -qm initial
base=$(git -C "$repo" rev-parse HEAD)

task="$test_dir/task.md"
cat > "$task" <<'EOF'
## 必須テスト
- 必須テストが差分に無ければ失敗する
- 必須テストがすべて差分にあれば通る
- 追加行に lint の無効化があれば失敗する
- lint の設定ファイルの変更は既定で失敗する
- lint の設定の変更を許す見出しがあれば警告だけにする
- 必須テストの見出しが無い task は照合を飛ばす
EOF

fail() {
  echo "assertion failed at line $1" >&2
  printf '%s\n' "${output-}" "${no_output-}" >&2
  exit 1
}

run_check() {
  set +e
  output=$(bash "$script" "$repo" "$task" "$base" 2>&1)
  status=$?
  set -e
}

# 必須テストが差分に無ければ失敗する
printf '%s\n' '# 必須テストが差分に無ければ失敗する' > "$repo/tests/first.sh"
git -C "$repo" add tests/first.sh
git -C "$repo" commit -qm first
run_check
{ [[ $status -eq 1 ]] && [[ "$output" == *"missing_tests="* ]]; } || fail "$LINENO"

# 必須テストがすべて差分にあれば通る
cat >> "$repo/tests/first.sh" <<'EOF'
# 必須テストが差分に無ければ失敗する
# 必須テストがすべて差分にあれば通る
# 追加行に lint の無効化があれば失敗する
# lint の設定ファイルの変更は既定で失敗する
# lint の設定の変更を許す見出しがあれば警告だけにする
# 必須テストの見出しが無い task は照合を飛ばす
EOF
run_check
{ [[ $status -eq 0 ]] && [[ "$output" == *"check_delivery: status=pass"* ]]; } || fail "$LINENO"

# 追加行に lint の無効化があれば失敗する
printf '%s\n' 'const unsafe = 1; // oxlint-'"disable"' no-unused-vars' >> "$repo/tests/first.sh"
run_check
{ [[ $status -eq 1 ]] && [[ "$output" == *"oxlint-disable"* ]]; } || fail "$LINENO"

# lint の設定ファイルの変更は既定で失敗する
sed 's/const value = 1;/const value = 2;/' "$repo/src.ts" > "$repo/.eslintrc.json"
run_check
{ [[ $status -eq 1 ]] && [[ "$output" == *"lint config"* ]]; } || fail "$LINENO"

# lint の設定の変更を許す見出しがあれば警告だけにする
cat >> "$task" <<'EOF'

## lint の設定の変更を許す
EOF
run_check
{ [[ $status -eq 1 ]] && [[ "$output" == *"oxlint-disable"* ]] && [[ "$output" == *"warning"* ]]; } || fail "$LINENO"
rm -f "$repo/.eslintrc.json"
sed -i.bak '/oxlint-/d' "$repo/tests/first.sh" && rm -f "$repo/tests/first.sh.bak"

# 必須テストの見出しが無い task は照合を飛ばす
no_tests_task="$test_dir/no-tests.md"
printf '%s\n' '# task' > "$no_tests_task"
run_check_no_heading() {
  set +e
  no_output=$(bash "$script" "$repo" "$no_tests_task" "$base" 2>&1)
  no_status=$?
  set -e
}
run_check_no_heading
{ [[ $no_status -eq 0 ]] && [[ "$no_output" == *"check_delivery: status=pass"* ]]; } || fail "$LINENO"

echo ok
