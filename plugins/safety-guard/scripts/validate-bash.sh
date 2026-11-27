#!/bin/bash
# PreToolUse hook: Bash コマンドの危険パターンを検証
# 文字列だけで決まる危険コマンドは settings.json の deny / ask に置き、ここには対象の状態やコマンドの構造を
# 見ないと決められない判定と、止めたときに代わりのコマンドを案内する判定だけを残す
# (rm / git rm -f / リモートブランチ削除 / chmod の 8 進 / 破壊的な git checkout)。
# rm 系 (rm -r/-f/-rf/-fr, git rm -f) は block ではなく permissionDecision=ask にする
# (対象が git の追跡ファイルだけなど、git から戻せる削除は ask しない)
# (settings.json の allow に "Bash" 全許可があるため、hook なしでは承認ゲートが素通りする。
#  意図的な削除を毎回ブロックせず、確認のうえ実行できるようにする)
# 危険パターンの照合は strip-shell-literals.pl で引用符の中身と heredoc の本文を除いた文字列に対して行う。
# 説明文として書いた commit メッセージ等が危険コマンドとして止まるのを防ぐため。シェルに渡す文字列
# (bash -c / eval の引数、bash が受ける heredoc の本文、"$(...)") は実行されるので除かない。

INPUT=$(cat)

# Bash ツール以外はスルー
if command -v jq > /dev/null 2>&1; then
  # jq は 1 回だけ起動する。command は改行を含みうるため NUL 区切りで受ける。
  { IFS= read -r -d '' TOOL; IFS= read -r -d '' COMMAND; IFS= read -r -d '' CWD; } < <(echo "$INPUT" | jq -j '((.tool_name? // "") | tostring) + "\u0000" + ((.tool_input.command? // "") | tostring) + "\u0000" + ((.cwd? // "") | tostring) + "\u0000"' 2>/dev/null)
else
  # jq フォールバック: grep で tool_name を抽出
  TOOL=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
  COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
fi

[[ "$TOOL" != "Bash" ]] && exit 0
[[ -z "$COMMAND" ]] && exit 0
[[ -n "$CWD" ]] || CWD="$PWD"

ask() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# 伝える文は貯めるだけにして末尾でまとめて出す。ここで exit すると、後ろの
# git rm -f・chmod・git checkout・git push --delete の検査に届かず block / ask が素通りする。
RECOMMENDS=""
recommend() {
  if [[ -n "$RECOMMENDS" ]]; then RECOMMENDS="$RECOMMENDS / $1"; else RECOMMENDS="$1"; fi
}
flush_recommends() {
  [[ -n "$RECOMMENDS" ]] || return 0
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$RECOMMENDS"
}

block() {
  printf '{"decision":"block","reason":"%s"}\n' "$1"
  exit 0
}

# 前処理 perl。テストは repo 内の source (executable_ 付き) を指す。
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# MATCH_COMMAND を行に分けて 1 度だけ作る。^ $ は行頭・行末として判定させたいので、
# 全体へ =~ をかけると意味が変わる (grep の行単位照合と同じになるよう行ごとに当てる)。
# hook は macOS 標準の /bin/bash(3.2)で起動されるため、mapfile や連想配列などの bash 4 以降の構文は
# 使わない(使っていた間はここで落ちて、以降の危険パターン判定がすべて素通りしていた)。
# rm の対象パス判定 (is_rm_target_safe) だけは前処理前の COMMAND を使う。引用符の中身を
# 消すと rm -rf "$HOME/x" が rm -rf "" になり、安全なパスに見えてしまうため。
MATCH_COMMAND=$(strip_literals "$COMMAND")
CMD_LINES=()
while IFS= read -r line || [ -n "$line" ]; do
  CMD_LINES+=("$line")
done <<< "$MATCH_COMMAND"

matches() {
  local line
  for line in "${CMD_LINES[@]}"; do
    [[ $line =~ $1 ]] && return 0
  done
  return 1
}

# セッションに紐付くブランチ作成・削除の判定は共通実装に置く。
# 通常コマンドでは Python を起動せず、git を含む呼び出しだけを渡す。
if [[ "$COMMAND" == *git* ]]; then
  # 判定の script と uv の起動役は同じディレクトリに置く。
  CLEANUP_POLICY="$HOOK_DIR/git-cleanup-policy.py"
  CLEANUP_RUNNER="$HOOK_DIR/run-with-uv"
  CLEANUP_RESULT=$(printf '%s' "$INPUT" | sh "$CLEANUP_RUNNER" "$CLEANUP_POLICY") || exit 2
  if [[ -n "$CLEANUP_RESULT" ]]; then
    printf '%s\n' "$CLEANUP_RESULT" | jq -c 'if .hookSpecificOutput.permissionDecision == "deny" then {decision: "block", reason: .hookSpecificOutput.permissionDecisionReason} else . end'
    exit 0
  fi
fi

# --- rm 系: block ではなく必ずユーザー確認 ---
# rm -rf / は復旧不能な全消去であり、確認ゲートを挟む余地がないため deny (settings.json) 側で維持する。
# ただし対象が /tmp 配下、.playwright-cli (実行由来の一時キャッシュ、復旧不要)、
# または worktree (.claude/worktrees/* の agent worktree、もしくは gwq の <repo>=<branch> 形式の
# worktree、repo 直下の .worktrees/<name>) に限られる場合は、使い捨てで再作成可能なため承認疲れを避けて自動許可する。
# 他パスが1つでも混じれば確認に倒す。

# dist/build/out/target/.next/.nuxt/.turbo はビルドツール (vite/tsc/webpack/cargo/next/nuxt/turbo 等) が
# 生成する成果物ディレクトリ、node_modules/.venv/venv/__pycache__/.pytest_cache は
# パッケージマネージャ/インタプリタが生成する依存・キャッシュディレクトリの慣例名で、
# 再ビルド・再インストールすれば復元できるため /tmp 等と同様に自動許可の対象にする。

# $COMMAND は複数行/複数コマンドの Bash 呼び出し全体を含み得る。rm を含む行以外に
# cd や git status のような無害なコマンドが混じっているだけで安全判定を巻き込まないよう、
# rm の呼び出しを含む行だけを抽出してその行のトークンのみを検査する。
# 対象が git の追跡ファイルだけで、消しても git から戻せるなら 0 (2026-10-15 ユーザー指定: 戻せる削除で止めない)。
# repo の内側でも未追跡・ignored のファイル (.env、ローカル DB、作業中のメモ) は git から戻せないので 1。
# 展開を読み切れない対象 ($VAR、$(...)、~、..)、repo の root 自体、.git、.git に当たりうる .* の glob も 1。
# 未 commit の変更を含む追跡ファイルは HEAD までは戻せるので 0 にし、RM_MODIFIED に積んで呼び出し側で添える。
# $1: rm の対象トークン、$2: その時点の作業ディレクトリ (cd を読み切れなければ空)
RM_MODIFIED=""
path_is_git_recoverable() {
  local token=$1 base=$2 abs dir root target status
  case "$token" in *'$'*|*'`'*|'~'*|*..*|*'{'*) return 1 ;; esac
  if [[ "$token" == /* ]]; then
    abs=$token
  else
    [[ -n "$base" ]] || return 1
    abs=$base/$token
  fi
  while [[ "$abs" == */ || "$abs" == */. ]]; do
    abs=${abs%/}
    abs=${abs%/.}
  done
  [[ -n "$abs" ]] || return 1
  case "/$abs/" in */.git/*) return 1 ;; esac
  case "${abs##*/}" in .*[*?[]*) return 1 ;; esac
  dir=$(cd "${abs%/*}/" 2>/dev/null && pwd -P) || return 1
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  root=$(cd "$root" && pwd -P) || return 1
  target="$dir/${abs##*/}"
  [[ "$target" == "$root"/* ]] || return 1
  status=$(git -C "$root" status --porcelain --ignored -- "${target#"$root"/}" 2>/dev/null) || return 1
  [[ "$status" =~ (^|$'\n')('??'|'!!')' ' ]] && return 1
  [[ -n "$status" ]] && RM_MODIFIED="$RM_MODIFIED ${target#"$root"/}"
  return 0
}

is_rm_target_safe() {
  local seg trimmed cd_target stripped token safe_cwd=0 cur_dir="$CWD"
  RM_GIT_TRACKED=0
  local RM_SEG_RE='(^|[[:space:]])rm[[:space:]]+-[^[:space:]]*[rf][^[:space:]]*([[:space:]]|$)'
  # 行だけでなく ; && || | で連結された同一行内の複数コマンドも呼び出し単位に分割する。
  # 分割しないと "rm -rf .playwright-cli 2>/dev/null; echo done" のように後続コマンドの
  # トークン (echo, done) まで rm の削除対象パスとして誤判定してしまう。
  # 区切りごとに sed/awk/grep を起動すると長い複数行コマンドで秒単位の待ちになるため、
  # 前後空白の除去と rm 判定は bash 組み込みだけで行う。
  while IFS= read -r seg; do
    trimmed="${seg#"${seg%%[![:space:]]*}"}"
    # "cd <safe-dir> && rm -f <relative-path>" のように、安全なディレクトリへ cd した後の
    # 相対パス rm も対象にする (worktree 内で cd してから相対パスで rm するのが典型パターン)。
    # 安全でないディレクトリへの cd を挟んだら safe_cwd は解除する。
    if [[ "$trimmed" == cd\ * ]]; then
      read -r _ cd_target _ <<< "$trimmed"
      case "$cd_target" in
        /tmp|/tmp/*|*/tmp/*|.playwright-cli|.playwright-cli/*|*/.playwright-cli|*/.playwright-cli/*) safe_cwd=1 ;;
        .claude/worktrees|.claude/worktrees/*|*/.claude/worktrees|*/.claude/worktrees/*) safe_cwd=1 ;;
        .worktrees/*|*/.worktrees/*) [[ "$cd_target" == *..* ]] && safe_cwd=0 || safe_cwd=1 ;;
        */ghq/*=*|*/ghq/*=*/*) safe_cwd=1 ;;
        *) safe_cwd=0 ;;
      esac
      # git 追跡判定用に作業ディレクトリを追う。展開を読み切れない cd の後は相対パスを判定しない。
      case "$cd_target" in
        *'$'*|*'`'*|'~'*|'') cur_dir="" ;;
        /*) cur_dir=$cd_target ;;
        *) [[ -n "$cur_dir" ]] && cur_dir="$cur_dir/$cd_target" ;;
      esac
      continue
    fi
    # git rm は下の専用判定で扱う
    [[ ${seg//git rm/git-rm} =~ $RM_SEG_RE ]] || continue
    # 2>/dev/null, >/dev/null, 2>&1 のようなリダイレクトは rm の削除対象パスではないため、
    # トークン分割前に取り除く (放置すると /dev/null 等が未知パス扱いされ ask に倒れてしまう)。
    # "$DEST/dist" のようにダブル/シングルクォートで囲まれたパスはクォート文字が
    # 残ったままだと case パターンにマッチしないため、ここで除去する。
    stripped=$(echo "$seg" | sed -E 's/[0-9]*>&[0-9]*//g; s/[0-9]*(>>|>|<)[^[:space:]]*//g; s/["'"'"']//g')
    for token in $stripped; do
      case "$token" in
        rm|-*) continue ;;
        # for/while/if 等の制御構文と同じ行に rm が書かれると、シェルキーワード
        # (do/then/done 等) までトークン分割で拾ってしまい未知パス扱いで ask に
        # 誤爆する。パスではなく構文キーワードなので安全側スキップの対象にする。
        do|then|else|elif|fi|esac|done|in|for|while|until|if|case|select|function|time) continue ;;
        /tmp|/tmp/*|*/tmp/*|.playwright-cli|.playwright-cli/*|*/.playwright-cli|*/.playwright-cli/*) continue ;;
        # $TMPDIR はシェルが展開する一時ディレクトリで、hook 側では展開せず未知の $VAR として扱うと
        # 一時ファイルの削除にまで承認を求めてしまう。.. で抜ける指定だけは確認に倒す。
        \$TMPDIR|\$TMPDIR/*|\$\{TMPDIR\}|\$\{TMPDIR\}/*)
          [[ "$token" == *..* ]] && return 1
          continue ;;
        .claude/worktrees|.claude/worktrees/*|*/.claude/worktrees|*/.claude/worktrees/*) continue ;;
        # repo 直下の .worktrees/<name> に作る git worktree (2026-10-27 ユーザー指定: worktree の削除は確認しない)
        .worktrees/*|*/.worktrees/*)
          [[ "$token" == *..* ]] && return 1
          continue ;;
        */ghq/*=*|*/ghq/*=*/*) continue ;;
        dist|dist/*|*/dist|*/dist/*) continue ;;
        build|build/*|*/build|*/build/*) continue ;;
        out|out/*|*/out|*/out/*) continue ;;
        target|target/*|*/target|*/target/*) continue ;;
        .next|.next/*|*/.next|*/.next/*) continue ;;
        .nuxt|.nuxt/*|*/.nuxt|*/.nuxt/*) continue ;;
        .turbo|.turbo/*|*/.turbo|*/.turbo/*) continue ;;
        node_modules|node_modules/*|*/node_modules|*/node_modules/*) continue ;;
        .venv|.venv/*|*/.venv|*/.venv/*) continue ;;
        venv|venv/*|*/venv|*/venv/*) continue ;;
        __pycache__|__pycache__/*|*/__pycache__|*/__pycache__/*) continue ;;
        .pytest_cache|.pytest_cache/*|*/.pytest_cache|*/.pytest_cache/*) continue ;;
        *)
          # 未追跡でも使い捨てと読める作業用・キャッシュ・カバレッジの慣例名 (2026-10-15 ユーザー指定)。
          # その場で付けた名前 (lintneg 等) は中身を判断できないので確認のまま。
          # 絶対パスには当てない。~/.cache の下に repo を置くこともあり、*/.cache/* だと repo ごと通ってしまう。
          if [[ "$token" != /* && "$token" != ~* && "$token" != *..* ]]; then
            case "/$token/" in
              */tmp/*|*/.tmp/*|*/temp/*|*/.cache/*|*/coverage/*|*/.vite/*|*/.parcel-cache/*) continue ;;
            esac
          fi
          # safe_cwd 下では、絶対パス/ホームディレクトリ相対でなく "../" で上位に抜けない
          # 相対パスのみ安全とみなす (worktree 外に抜ける操作は確認に倒す)
          if [[ "$safe_cwd" == "1" && "$token" != /* && "$token" != ~* && "$token" != *..* ]]; then
            continue
          fi
          if path_is_git_recoverable "$token" "$cur_dir"; then
            RM_GIT_TRACKED=1
            continue
          fi
          return 1
          ;;
      esac
    done
  done <<< "$(printf '%s\n' "$COMMAND" | sed -E 's/(;|&&|\|\||\|)/\n/g')"
  return 0
}

# 確認しないときも permissionDecision は返さず、通常の許可判定 (auto mode では分類器) に任せる。
# allow を返すと連結された別コマンドまで一括で承認してしまうため。
matches_rm() {
  local line
  for line in "${CMD_LINES[@]}"; do
    # git rm は下の専用判定で扱う
    [[ ${line//git rm/git-rm} =~ (^|[[:space:]\;\&|])rm[[:space:]]+-[^[:space:]\;\&|]*[rf][^[:space:]\;\&|]*([[:space:]]|$) ]] && return 0
  done
  return 1
}

if matches_rm; then
  if is_rm_target_safe; then
    if [[ -n "$RM_MODIFIED" ]]; then
      recommend "対象は git の追跡ファイルなので確認しません。ただし未 commit の変更があり、消すと HEAD 以降の差分は戻せません:$RM_MODIFIED"
    elif [[ "$RM_GIT_TRACKED" == "1" ]]; then
      recommend '対象は git の追跡ファイル (または /tmp・生成物・worktree) だけで、git から戻せるため確認しません'
    else
      recommend '対象が /tmp、.playwright-cli、dist/build/out/target/.next/.nuxt/.turbo、node_modules/.venv/venv/__pycache__/.pytest_cache、または worktree (.claude/worktrees/*, .worktrees/*, gwq の <repo>=<branch>) 配下のみのため rm を自動許可します'
    fi
  else
    ask 'rm による削除コマンドです。対象に git から戻せないファイル (未追跡・ignored・repo の外・.git) が含まれる可能性があります。対象パスと影響範囲を確認のうえ、実行してよいか承認してください'
  fi
fi

# git rm は -f / --force が無ければ、git 自身が未追跡ファイルに触れず、変更中のファイルの削除も拒むので確認しない。
# -f のときだけ、変更中の差分を捨てうるため対象を調べる。
is_git_rm_force_safe() {
  local seg token after_rm
  RM_MODIFIED=""
  while IFS= read -r seg; do
    [[ $seg =~ (^|[[:space:]])git[[:space:]]+rm([[:space:]]|$) ]] || continue
    after_rm=0
    for token in $(echo "$seg" | sed -E 's/[0-9]*>&[0-9]*//g; s/[0-9]*(>>|>|<)[^[:space:]]*//g; s/["'"'"']//g'); do
      if [[ "$after_rm" == "0" ]]; then
        [[ "$token" == rm ]] && after_rm=1
        continue
      fi
      case "$token" in -*) continue ;; esac
      path_is_git_recoverable "$token" "$CWD" || return 1
    done
  done <<< "$(printf '%s\n' "$COMMAND" | sed -E 's/(;|&&|\|\||\|)/\n/g')"
  [[ -z "$RM_MODIFIED" ]]
}

if matches '(^|[[:space:];&|])git[[:space:]]+rm[[:space:]]+([^;&|]*[[:space:]])?(-[^-[:space:];&|]*f[^[:space:];&|]*|--force)([[:space:]]|$)'; then
  if ! is_git_rm_force_safe; then
    ask 'git rm -f です。未 commit の変更や git から戻せないファイルを消す可能性があります。対象パスと影響範囲を確認のうえ、実行してよいか承認してください'
  fi
fi

# kill / pkill / killall / fuser -k はプロセス終了に留まりデータ消失を伴わないため rm ほど危険ではなく、
# autoMode の通常 Bash 許可に委ねる (ask ゲートは設けない)。

# --- chmod の 8 進で他ユーザーに書き込みを許す変更は確認 ---
# chmod -R / o+w / a+w、chown、systemctl / service の変更系は文字列だけで決まるので
# settings.json の ask / deny に置いた。8 進 (777 など) は wildcard で列挙できないのでここに残す。
if matches '(^|[[:space:];&|])chmod[[:space:]]+[0-7]{2}[2367]([[:space:]]|$)'; then
  ask 'chmod で他ユーザーに書き込み権限を与える変更です。対象パスと影響範囲を確認のうえ、実行してよいか承認してください'
fi

# --- git checkout: 破壊的形式は block、それ以外は新コマンドを推奨 ---
# settings.json の deny も同じ形を止めるが、deny は理由を返さない。代わりのコマンドを案内するためにここでも止める。

if matches '(^|[[:space:];&|])git[[:space:]]+checkout[[:space:]]+(-B|-f|--force|--|\.)([[:space:]]|$)' || \
  matches '(^|[[:space:];&|])git[[:space:]]+checkout[[:space:]].*[[:space:]]--[[:space:]]'; then
  block "危険なパターンが検出されました: Git checkout による破壊的な上書き。ブランチ移動は git switch、作業ツリーの変更を捨てるなら対象を示してユーザーに ! git checkout -- <path> を頼む(git stash はほかのセッションの変更を巻き込むので使わない)、コミット済み変更を打ち消す場合は git revert <commit>、内容確認だけなら git diff / git show を使ってください"
fi

# --- git push --delete / -d: 削除する ref がすべて作業ブランチの接頭辞なら通す ---
# 作業ブランチはマージ後に消すもので、消しても PR と手元の remote-tracking ref の reflog から戻せる。
# main などの共有ブランチは戻すのに他人の手が要るので止める。; & | と改行で区切ったコマンドごとに、
# remote を除く位置引数をすべて見る（ref を 1 つも書かない削除も止める）。
DELETABLE_BRANCH='^(claude|feature|features|feat|fix|issue|issues|chore)/[A-Za-z0-9._/-]+$'
push_deletes_only_work_branches() {
  # $1: ; & | を含まない 1 コマンド。git push の削除でなければ 0
  local token seen_git=false in_push=false skip_next=false deleting=false remote_seen=false
  local refs=() words=()
  # for token in $1 だと claude/* のような引数が glob 展開されるので read -a で分ける
  read -r -a words <<< "$1"
  for token in "${words[@]}"; do
    if [[ "$in_push" == false ]]; then
      if [[ "$seen_git" == false ]]; then
        [[ "$token" == git ]] && seen_git=true
      elif [[ "$skip_next" == true ]]; then
        skip_next=false
      elif [[ "$token" == -C || "$token" == -c ]]; then
        skip_next=true
      elif [[ "$token" == push ]]; then
        in_push=true
      else
        return 0
      fi
      continue
    fi
    case "$token" in
      --delete|-d) deleting=true ;;
      -*) ;;
      *)
        if [[ "$remote_seen" == false ]]; then
          remote_seen=true
        else
          refs+=("$token")
        fi
        ;;
    esac
  done
  [[ "$deleting" == false ]] && return 0
  [[ ${#refs[@]} -eq 0 ]] && return 1
  for token in "${refs[@]}"; do
    [[ $token =~ $DELETABLE_BRANCH ]] || return 1
  done
  return 0
}
for line in "${CMD_LINES[@]}"; do
  while IFS= read -r segment || [ -n "$segment" ]; do
    push_deletes_only_work_branches "$segment" || \
      block "危険なパターンが検出されました: 作業ブランチ以外のリモートブランチ削除。削除してよいのは claude/ feature/ features/ feat/ fix/ issue/ issues/ chore/ で始まるブランチだけです"
  done <<< "$(printf '%s' "$line" | tr ';&|' '\n\n\n')"
done

# git push origin :<ref> の削除は settings.json の deny に書けない (末尾の :* は「 *」と同じ意味になり push 全体を拒否する)。
# find -delete、git reset --hard、force push、dd、mkfs など文字列だけで決まる破壊は settings.json の deny が止める。
if matches '(^|[[:space:];&|])git[[:space:]]+push[[:space:]].*[[:space:]]:([^[:space:]]+)'; then
  block '危険なパターンが検出されました: Git push によるリモート参照削除'
fi

if matches '(^|[[:space:];&|])git[[:space:]]+checkout[[:space:]]+-b([[:space:]]|$)'; then
  recommend 'git checkout -b は実行できますが、ブランチ作成には git switch -c を推奨します'
elif matches '(^|[[:space:];&|])git[[:space:]]+checkout[[:space:]]+--detach([[:space:]]|$)'; then
  recommend 'git checkout --detach は実行できますが、detached HEAD への移動には git switch --detach を推奨します'
elif matches '(^|[[:space:];&|])git[[:space:]]+checkout[[:space:]]+HEAD([[:space:];&|]|$)'; then
  recommend '単独の git checkout HEAD は実行できますが、detached HEAD への移動には git switch --detach HEAD を推奨します'
elif matches '(^|[[:space:];&|])git[[:space:]]+checkout([[:space:]]|$)'; then
  recommend 'git checkout は実行できますが、ブランチ操作には git switch を推奨します'
fi

# --- pre-commit hook が実際に含むチェックの先回り二重実行への気づき ---
# lint/format/deploy-contexts 系チェックを pre-commit hook が持つ repo で手動実行すると、
# commit 時に hook がもう一度同じチェックを走らせる。ブロックはしない(開発中の任意タイミングでの
# 実行は正当)が、一言添えて二重実行に気づけるようにする(ある monorepo で実測: 1 app 変更のたびに
# 手動 lint/format:check/deploy-contexts → commit → hook 再実行、を繰り返していた)。
# 判定は「pre-commit が存在するか」ではなく「pre-commit の中身にそのチェックが書かれているか」で行う
# (2026-09-10: git hook は既定で置かない方針になり、その repo の pre-commit から lint を外した
#  結果、存在だけを見る旧判定では pnpm lint に対して嘘の案内を出していた)。
precommit_hook_file() {
  local hooks_dir root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  hooks_dir=$(git config core.hooksPath 2>/dev/null)
  if [[ -z "$hooks_dir" ]]; then
    hooks_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)/hooks"
  elif [[ "$hooks_dir" != /* ]]; then
    hooks_dir="$root/$hooks_dir" # core.hooksPath の相対パスは作業ツリー root 基準
  fi
  [[ -f "$hooks_dir/pre-commit" && -x "$hooks_dir/pre-commit" ]] || return 1
  printf '%s\n' "$hooks_dir/pre-commit"
}

# $1: pre-commit の中身に対する ERE。含まれていれば 0。
precommit_hook_runs() {
  local file
  file=$(precommit_hook_file) || return 1
  grep -Eq "$1" "$file"
}

# 手動実行しようとしているチェックを 1 つ特定し、同じチェックが pre-commit の中身にあるときだけ案内する。
PM_PREFIX='(pnpm|npm|yarn|bun)[[:space:]]+(run[[:space:]]+)?'
precommit_check_pattern=''
if matches "(^|[[:space:];&|])${PM_PREFIX}lint([[:space:]]|$)"; then
  precommit_check_pattern="${PM_PREFIX}lint([[:space:]]|$)"
elif matches "(^|[[:space:];&|])${PM_PREFIX}format:check([[:space:]]|$)"; then
  precommit_check_pattern="${PM_PREFIX}format:check([[:space:]]|$)"
elif matches "(^|[[:space:];&|])${PM_PREFIX}check:deploy-contexts([[:space:]]|$)"; then
  precommit_check_pattern="${PM_PREFIX}check:deploy-contexts([[:space:]]|$)"
elif matches '(^|[[:space:];&|])oxlint([[:space:]]|$)'; then
  precommit_check_pattern='oxlint([[:space:]]|$)'
elif matches '(^|[[:space:];&|])prettier[[:space:]]+--check([[:space:]]|$)'; then
  precommit_check_pattern='prettier[[:space:]]+--check([[:space:]]|$)'
fi
if [[ -n "$precommit_check_pattern" ]] && precommit_hook_runs "$precommit_check_pattern"; then
  recommend 'このチェックは pre-commit hook が commit 時に自動実行します(hook の中身に同じコマンドがあります)。commit 直前の先回り確認が目的なら再実行は不要です(開発中の任意タイミングでの実行は問題ありません)'
fi

flush_recommends
exit 0
