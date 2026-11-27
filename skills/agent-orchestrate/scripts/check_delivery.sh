#!/usr/bin/env bash
# task の必須テストと lint 層の差分を機械的に照合する。
set -euo pipefail

[[ $# -ge 2 && $# -le 3 ]] || {
  echo "usage: check_delivery.sh <repo> <task-file> [base-commit]" >&2
  exit 2
}
repo=$(cd "$1" && pwd)
task=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
base=${3:-HEAD}
[[ -f "$task" ]] || { echo "error: task file が無い: $task" >&2; exit 2; }
git -C "$repo" rev-parse --verify "$base^{commit}" >/dev/null || { echo "error: base commit が無い: $base" >&2; exit 2; }

missing_tests=0
lint_disables=0
lint_config=0
allow_lint_config=0
if grep -q '^## lint の設定の変更を許す[[:space:]]*$' "$task"; then
  allow_lint_config=1
fi

# 追加行をファイル名と行番号付きで一時ファイルへ集める。
added_file=$(mktemp /tmp/check-delivery-added.XXXXXX)
cleanup() { rm -f "$added_file"; }
trap cleanup EXIT

# 未追跡のテストファイルは内容全体を追加行として扱う。
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  case "$file" in
    tests/*|test/*|*/*tests/*|*.test.*|*.spec.*|__tests__/*)
      awk -v file="$file" '{ print file ":" NR ":" $0 }' "$repo/$file" >> "$added_file"
      ;;
  esac
done < <(git -C "$repo" ls-files --others --exclude-standard)

# tracked diff の結果を追加行ファイルへ保存する（上の表示用抽出を再利用）。
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  git -C "$repo" diff --unified=0 "$base" -- "$file" | awk -v file="$file" '
    BEGIN { line = 0 }
    /^@@ / { h = $3; sub(/^\+/, "", h); sub(/,.*/, "", h); line = h; next }
    /^\+[^+]/ { print file ":" line ":" substr($0, 2); line++; next }
    /^ / { line++; next }
  '
done < <(git -C "$repo" diff --name-only "$base" --) >> "$added_file"

# 必須テスト見出しがあるときだけ、箇条書きの文字列を照合する。
in_tests=0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == "## 必須テスト" ]]; then in_tests=1; continue; fi
  [[ "$line" == "## "* ]] && { in_tests=0; continue; }
  (( in_tests )) || continue
  [[ "$line" == '- '* ]] || continue
  expected=${line#- }
  if [[ "$expected" == \`*\` ]]; then expected=${expected:1:${#expected}-2}; fi
  if ! grep -Fq -- "$expected" "$added_file"; then
    echo "missing test: $expected"
    missing_tests=$((missing_tests + 1))
  fi
done < "$task"

# 追加行の抑制コメントを検出する。
oxlint_disable='oxlint-'"disable"
eslint_disable='eslint-'"disable"
biome_ignore='biome-'"ignore"
ts_ignore='@ts-'"ignore"
ts_nocheck='@ts-'"nocheck"
ts_expect='@ts-'"expect-error"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == *"$oxlint_disable"* || "$line" == *"$eslint_disable"* || "$line" == *"$biome_ignore"* || "$line" == *"$ts_ignore"* || "$line" == *"$ts_nocheck"* ]]; then
    echo "lint disable: $line"
    lint_disables=$((lint_disables + 1))
  elif [[ "$line" == *"$ts_expect"* ]]; then
    echo "warning: @ts-expect-error: $line"
  fi
done < "$added_file"

# lint 設定ファイルの差分を検出する。
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  case "$(basename "$file")" in
    .oxlintrc*|oxlint.config.*|lint.config.*|eslint.config.*|.eslintrc*|biome.json*)
      echo "lint config changed: $file"
      lint_config=$((lint_config + 1))
      ;;
    vite.config.*)
      if git -C "$repo" diff "$base" -- "$file" | grep -q 'lint'; then
        echo "lint config changed: $file"
        lint_config=$((lint_config + 1))
      fi
      ;;
  esac
done < <(git -C "$repo" diff --name-only "$base" --)
while IFS= read -r file; do
  case "$(basename "$file")" in
    .oxlintrc*|oxlint.config.*|lint.config.*|eslint.config.*|.eslintrc*|biome.json*|vite.config.*)
      echo "lint config changed: $file"
      lint_config=$((lint_config + 1))
      ;;
  esac
done < <(git -C "$repo" ls-files --others --exclude-standard)

if (( allow_lint_config && lint_config > 0 )); then
  echo "warning: lint config change allowed by task"
  lint_config=0
fi
status=pass
if (( missing_tests || lint_disables || lint_config )); then status=fail; fi
echo "check_delivery: status=$status missing_tests=$missing_tests lint_disables=$lint_disables lint_config=$lint_config"
[[ "$status" == pass ]]
