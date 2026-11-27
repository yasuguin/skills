#!/bin/bash
# PreToolUse hook: banned-pattern registry の汎用エンジン
#
# 第1引数でどちらのregistryを使うか切り替える。第2引数は registry のパスで、省略時はこのスクリプトと
# 同じディレクトリの <mode>-banned-pattern.json。
#   ui      -> 対象: Write/Edit/NotebookEditの書き込み内容 (拡張子でスコープ)
#   command -> 対象: Bashコマンド文字列
#
# ルールの追加/編集はJSON編集のみで完結させ、このスクリプト自体は触らない運用にする
# (ban-rule-manager skill 参照)。jq必須。無ければfail open (何もしない)。
# command側のuiパターンをBashコマンド文字列に流用しない理由: `rg 'linear-gradient'` のような
# 正規のgrep検索コマンド自体を誤検知でblockしてしまうため。UI系はcontentのみ、command系は
# COMMANDのみを見る棲み分けを維持する。
# rule の path_patterns は拡張子で表せない対象 (拡張子なしの Dockerfile、テストファイルだけ) を
# パスの ERE で絞るために足した。extensions と併用したときは両方を満たすものだけを対象にする。
# 全 deny パターンを 1 回の grep で照合し、当たらなければ即 exit する高速経路を持つ。
# ルールごとに jq / grep を起動すると PreToolUse の全 Bash 呼び出しで待ちが積み上がるため。
# 当たったときだけ従来のルール別評価に戻すので、allow の判定と評価順は変わらない。
# command 側は照合前に strip-shell-literals.pl で引用符の中身と heredoc の本文を除く。説明文として
# 書いた commit メッセージや grep の検索語が、コマンドとして止まるのを防ぐため。シェルに渡す文字列
# (bash -c / eval の引数、bash が受ける heredoc の本文、"$(...)") は実行されるので除かない。

MODE="$1"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${2:-$HOOK_DIR/${MODE}-banned-pattern.json}"

# 前処理 perl は同じディレクトリに置く。source のまま動かすテストでは executable_ 付きの名前になる。
STRIP_LITERALS="$HOOK_DIR/executable_strip-shell-literals.pl"
[[ -f "$STRIP_LITERALS" ]] || STRIP_LITERALS="$HOOK_DIR/strip-shell-literals.pl"

# 照合用の文字列を返す。前処理が失敗したら元の文字列で照合する (判定を緩めて素通りさせない)。
strip_literals() {
  local stripped
  stripped=$(printf '%s' "$1" | perl "$STRIP_LITERALS" 2>/dev/null) || { printf '%s' "$1"; return; }
  if [[ -z "$stripped" && -n "$1" ]]; then
    printf '%s' "$1"
    return
  fi
  printf '%s' "$stripped"
}

command -v jq > /dev/null 2>&1 || exit 0
[[ -f "$REGISTRY" ]] || exit 0

INPUT=$(cat)

# 入力の 4 項目を 1 回の jq で取り出す。値は改行を含みうるため NUL 区切りで受ける。
{
  IFS= read -r -d '' TOOL
  IFS= read -r -d '' COMMAND
  IFS= read -r -d '' FILE
  IFS= read -r -d '' CONTENT_RAW
  IFS= read -r -d '' OLD_STRING
} < <(echo "$INPUT" | jq -j '
  ((.tool_name? // "") | tostring) + "\u0000" +
  ((.tool_input.command? // "") | tostring) + "\u0000" +
  ((.tool_input.file_path? // .tool_input.notebook_path? // "") | tostring) + "\u0000" +
  ((.tool_input.content? // .tool_input.new_string? // .tool_input.new_source? // "") | tostring) + "\u0000" +
  ((.tool_input.old_string? // "") | tostring) + "\u0000"
' 2>/dev/null)

block() {
  printf '{"decision":"block","reason":"%s"}\n' "$1"
  exit 0
}

any_match() {
  # $1: 検査対象文字列, $2: 改行区切りpattern一覧, $3: grepフラグ(通常 "-qE" か "-qEi")
  local target="$1" patterns="$2" flags="$3" pat
  [[ -z "$patterns" ]] && return 1
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    # shellcheck disable=SC2086
    if echo "$target" | grep $flags "$pat" > /dev/null 2>&1; then
      return 0
    fi
  done <<< "$patterns"
  return 1
}

# ルールを 1 回の jq で読む。各ルールは NUL 区切りの 5 項目 (deny / allow / message / extensions / path_patterns) で、
# パターン一覧は改行で連結してある (any_match が改行で分ける)。
RULE_DENY=(); RULE_ALLOW=(); RULE_MSG=(); RULE_EXTS=(); RULE_PATHS=()
while IFS= read -r -d '' deny && IFS= read -r -d '' allow && IFS= read -r -d '' msg && IFS= read -r -d '' exts && IFS= read -r -d '' paths; do
  RULE_DENY+=("$deny"); RULE_ALLOW+=("$allow"); RULE_MSG+=("$msg"); RULE_EXTS+=("$exts"); RULE_PATHS+=("$paths")
done < <(jq -j '.rules[]? | (
  ((.deny_patterns? // []) | join("\n")) + "\u0000" +
  ((.allow_patterns? // []) | join("\n")) + "\u0000" +
  ((.message? | tostring)) + "\u0000" +
  ((.extensions? // []) | join("\n")) + "\u0000" +
  ((.path_patterns? // []) | join("\n")) + "\u0000"
)' "$REGISTRY" 2>/dev/null)

# 指定ルールの deny を空行を除いて ALL_DENY に連結する。
# 空行は grep -f で全行に当たるため落とす (any_match が空行をスキップする仕様と合わせる)。
collect_deny() {
  local i pat
  ALL_DENY=""
  for i in "$@"; do
    while IFS= read -r pat; do
      [[ -n "$pat" ]] && ALL_DENY+="$pat"$'\n'
    done <<< "${RULE_DENY[i]}"
  done
}

# ALL_DENY のどれも対象に当たらないなら 0。grep の終了コード 1 だけをこの判定にする。
# 2 (不正なパターンで組めない) は当たり判定が付かないので、ルール別ループに任せる。
none_denied() {
  # $1: 照合対象, $2: grep フラグ
  local rc
  # shellcheck disable=SC2086
  echo "$1" | grep $2 -f <(printf '%s' "$ALL_DENY") > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 1 ]]
}

if [[ "$MODE" == "command" ]]; then
  [[ "$TOOL" != "Bash" ]] && exit 0
  [[ -z "$COMMAND" ]] && exit 0

  MATCH_TARGET=$(strip_literals "$COMMAND")
  collect_deny "${!RULE_DENY[@]}"
  none_denied "$MATCH_TARGET" "-qE" && exit 0

  for i in "${!RULE_DENY[@]}"; do
    any_match "$MATCH_TARGET" "${RULE_DENY[i]}" "-qE" || continue
    any_match "$MATCH_TARGET" "${RULE_ALLOW[i]}" "-qE" && continue
    block "${RULE_MSG[i]}"
  done
  exit 0
fi

if [[ "$MODE" == "ui" ]]; then
  if [[ "$TOOL" != "Write" && "$TOOL" != "Edit" && "$TOOL" != "NotebookEdit" && "$TOOL" != "apply_patch" ]]; then
    exit 0
  fi

  # apply_patch (Codex) は file_path を持たず、tool_input.command に diff テキスト
  # 全体が入る。ヘッダー行 "*** (Add|Update) File: <path>" から対象ファイルの
  # 拡張子一覧を集め、その中に登録拡張子が1つでもあればルールを適用する
  # (単一ファイルの file_path 前提だった拡張子スコープ判定を複数ファイル対応に拡張)。
  if [[ "$TOOL" == "apply_patch" ]]; then
    CONTENT="$COMMAND"
    [[ -z "$CONTENT" ]] && exit 0
    PATCH_EXTS=$(echo "$CONTENT" | grep -oE '^\*\*\* (Add|Update) File: .+' \
      | sed -E 's/^\*\*\* (Add|Update) File: //; s/.*\.//' | sort -u)
    TARGET_PATHS=$(echo "$CONTENT" | grep -oE '^\*\*\* (Add|Update) File: .+' \
      | sed -E 's/^\*\*\* (Add|Update) File: //')
  else
    CONTENT="$CONTENT_RAW"
    # Edit は足した行(old_string に同じ行が無い行)だけを見る。禁止は新規導入に対するもので、既存の行を含む塊を
    # 直すだけで止まっていた(2026-11-26。ui-zero-offset-shadow で既存の shadow-sm の隣を直したとき)
    if [[ "$TOOL" == "Edit" && -n "$OLD_STRING" ]]; then
      CONTENT=$(printf '%s\n' "$CONTENT" | grep -vxF -f <(printf '%s\n' "$OLD_STRING") 2>/dev/null)
    fi
    [[ -z "$CONTENT" ]] && exit 0
    PATCH_EXTS="${FILE##*.}"
    TARGET_PATHS="$FILE"
  fi

  path_in_scope() {
    # $1: rule の path_patterns。対象パスのどれか 1 つに当たれば 0
    local pp="$1" p
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      any_match "$p" "$pp" "-qE" && return 0
    done <<< "$TARGET_PATHS"
    return 1
  }

  ext_in_scope() {
    local exts="$1" pe
    while IFS= read -r pe; do
      [[ -z "$pe" ]] && continue
      [[ $'\n'"$exts"$'\n' == *$'\n'"$pe"$'\n'* ]] && return 0
    done <<< "$PATCH_EXTS"
    return 1
  }

  SCOPED=()
  for i in "${!RULE_EXTS[@]}"; do
    [[ -n "${RULE_EXTS[i]}" ]] && ! ext_in_scope "${RULE_EXTS[i]}" && continue
    [[ -n "${RULE_PATHS[i]}" ]] && ! path_in_scope "${RULE_PATHS[i]}" && continue
    SCOPED+=("$i")
  done

  collect_deny "${SCOPED[@]}"
  none_denied "$CONTENT" "-qEi" && exit 0

  # ルールごとに「deny に当たる行を grep -f で抜き出し、allow に当たる行を grep -v -f で除く」の 2 回で判定する。
  # 以前は行 × パターンごとに grep を起動していて、当たりのある 154 行の e2e spec の Write で 1 万回を超え、
  # PreToolUse が 600 秒のタイムアウトまで止まった（2026-10-27）。
  # パターンが不正で grep -f が組めない（終了コード 2）ルールだけ、1 本ずつの照合に戻す。
  for i in "${SCOPED[@]}"; do
    deny=$(grep -v '^$' <<< "${RULE_DENY[i]}")
    allow=$(grep -v '^$' <<< "${RULE_ALLOW[i]}")
    [[ -z "$deny" ]] && continue
    hits=$(printf '%s\n' "$CONTENT" | grep -Ei -f <(printf '%s\n' "$deny") 2>/dev/null)
    rc=$?
    if [[ $rc -eq 0 && -n "$allow" ]]; then
      hits=$(printf '%s\n' "$hits" | grep -vEi -f <(printf '%s\n' "$allow") 2>/dev/null)
      rc=$?
    fi
    if [[ $rc -eq 2 ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        any_match "$line" "${RULE_DENY[i]}" "-qEi" || continue
        any_match "$line" "${RULE_ALLOW[i]}" "-qEi" && continue
        block "${RULE_MSG[i]}"
      done <<< "$CONTENT"
      continue
    fi
    [[ $rc -eq 0 && -n "$hits" ]] && block "${RULE_MSG[i]}"
  done
  exit 0
fi

exit 0
