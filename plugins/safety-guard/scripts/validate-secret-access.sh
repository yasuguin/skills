#!/bin/bash
# PreToolUse hook: シークレット類の読み出しを block する
# settings.json の deny リスト (Read(.env) や cat ~/.ssh/* 等) はパス直下や特定コマンドしか
# 塞げないため、age 鍵・SSH/クラウド認証情報・サブディレクトリの .env・head/grep/base64 等の
# 読み出し経路をまとめてここで塞ぐ。公開鍵 (*.pub)・暗号文 (*.age)・.env.example 系・certifi の cacert.pem・
# `cp .env.example .env` は許可。

INPUT=$(cat)

if command -v jq > /dev/null 2>&1; then
  TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
else
  TOOL=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
fi

block() {
  printf '{"decision":"block","reason":"%s"}\n' "$1"
  exit 0
}

# --- Read: シークレットパスを block ---

if [[ "$TOOL" == "Read" ]]; then
  if command -v jq > /dev/null 2>&1; then
    FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  else
    FILE=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
  fi
  [[ -z "$FILE" ]] && exit 0

  if echo "$FILE" | grep -qE '/\.ssh/' && ! echo "$FILE" | grep -qE '\.pub$'; then
    block 'SSH 関連ファイルの読み取りは禁止です (公開鍵 *.pub のみ可)'
  fi
  if echo "$FILE" | grep -qE '/\.(aws|config/age)/'; then
    block 'クラウド認証情報・age 秘密鍵の読み取りは禁止です'
  fi
  if echo "$FILE" | grep -qE 'application_default_credentials\.json$|/\.config/gcloud/(credentials|legacy_credentials)'; then
    block 'gcloud 認証情報の読み取りは禁止です'
  fi
  if echo "$FILE" | grep -qE '(^|/)\.env(\.[A-Za-z0-9._-]+)?$' \
     && ! echo "$FILE" | grep -qE '\.env(\.[A-Za-z0-9_-]+)*\.(example|sample|template)$'; then
    block '.env ファイルの読み取りは禁止です (.env.example 系のみ可)'
  fi
  if echo "$FILE" | grep -qE '\.pem$|/id_(rsa|ed25519|ecdsa|dsa)$|/\.netrc$|/secrets/global\.env$' \
     && ! echo "$FILE" | grep -qE '/certifi/cacert\.pem$'; then
    block '秘密鍵・認証情報ファイルの読み取りは禁止です'
  fi
  exit 0
fi

# --- Bash: 読み出し系コマンド × シークレットパスの組み合わせを block ---

[[ "$TOOL" != "Bash" ]] && exit 0

if command -v jq > /dev/null 2>&1; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
fi
[[ -z "$COMMAND" ]] && exit 0

# 内容を読み出せるコマンドのみ対象 (ls 等の一覧系は許可)
READER_RE='(^|[[:space:];&|(])(cat|head|tail|less|more|bat|grep|rg|sed|awk|cut|paste|sort|uniq|strings|xxd|od|base64|openssl|cp|scp|rsync|tee|dd|age|nl|diff|jq|python3?|node|deno|bun|ruby|perl|php|bash|sh|zsh|source)([[:space:]]|$)|(^|[;&|(])[[:space:]]*\.[[:space:]]'
echo "$COMMAND" | grep -qE "$READER_RE" || exit 0

# 雛形から .env を作る `cp .env.example .env` は読み出しではないので外す（2026-11-26 ユーザー決定。親 issue #14）。
# .env.example 系の言及は無害なので除外してから判定する。
# .env.local.example のように環境名を含む例も許可する。
CLEAN=$(echo "$COMMAND" | perl -pe 's{\bcp\s+(?:-\S+\s+)*\S*\.env(?:\.[A-Za-z0-9_-]+)*\.(?:example|sample|template)\s+\S*\.env(?:\.[A-Za-z0-9_-]+)?(?=[\s;&|)]|$)}{cp}g' \
  | sed -E 's/\.env(\.[A-Za-z0-9_-]+)*\.(example|sample|template)//g')

# 書き出すだけの heredoc（git commit / git tag / gh --body-file - / cat > / tee が受ける）は本文を判定から外す。
# commit message やレポートの本文で .env に触れただけで止まっていたため。
# python・node・bash などに渡す heredoc は中でファイルを開けるので、本文を残して判定する。
# 中身を読まない存在確認（test / [ / ls の引数）の .env も外す。読み出しと同じ行にあっても、読み出し側は残るので止まる。
CLEAN=$(printf '%s\n' "$CLEAN" | perl -e '
  my @out; my $skip;
  for (<STDIN>) {
    if (defined $skip) { $skip = undef if /^\s*\Q$skip\E\s*$/; next; }
    if (/<<-?\s*["\x27]?(\w+)["\x27]?/) {
      my $delim = $1;
      $skip = $delim if /\bgit\s+(commit|tag)\b|\bgh\b.*--body-file\s+-|\bcat\b[^|;&]*>|\btee\b/;
    }
    push @out, $_;
  }
  my $s = join "", @out;
  $s =~ s{(\btest\s+-[a-z]\s+|\[\s+-[a-z]\s+)\S*\.env\S*}{$1}g;
  $s =~ s{(\bls\b[^;&|\n]*)}{ (my $seg = $1) =~ s/\S*\.env(\.[A-Za-z0-9._-]+)?(?=\s|$)//g; $seg }ge;
  # 引用符で囲んだ検索語（grep / rg の最初の引数、-e）と commit の本文（-m）は読み出す先ではないので外す。
  # 鍵のパスを検索語に書いただけで止まっていた。対象のファイルは引用符の外に残るので、読み出しは止まる。
  my $q = qr{\x27[^\x27]*\x27|"(?:[^"\\]|\\.)*"};
  $s =~ s{(\b(?:grep|rg|ag|ack)\b(?:\s+-[-\w=]+)*\s+)$q}{$1}g;
  $s =~ s{((?:^|\s)(?:-m|--message)(?:=|\s+))$q}{$1}g;
  # -e は node -e / perl -e / ruby -e ではコード本体なので、検索語として外すのは grep 系の行だけ
  $s =~ s{(\b(?:grep|rg|ag|ack)\b[^|;&\n]*?\s(?:-e|--regexp)(?:=|\s+))$q}{$1}g;
  # 公開の CA の名簿（certifi の cacert.pem）は秘密ではない（2026-11-26 ユーザー決定）
  $s =~ s{\S*/certifi/cacert\.pem}{}g;
  print $s;
')

# 引用符は ' も境界にする（python の open('.env') のような参照も拾う）
BOUND="([[:space:];&|\"')]|\$)"
HOME_RE='(~|\$HOME|/home/[^/[:space:]]+|/Users/[^/[:space:]]+)'  # public: allow（ホームを見張る正規表現）

if echo "$CLEAN" | grep -qE "${HOME_RE}/\.ssh/" && ! echo "$CLEAN" | grep -qE '\.pub'; then
  block 'SSH 関連ファイルの読み出しは禁止です (公開鍵 *.pub のみ可)'
fi
if echo "$CLEAN" | grep -qE "${HOME_RE}/\.aws/|\.config/age/"; then
  block 'クラウド認証情報・age 秘密鍵の読み出しは禁止です'
fi
if echo "$CLEAN" | grep -qE "application_default_credentials\.json|\.config/gcloud/(credentials|legacy_credentials)"; then
  block 'gcloud 認証情報の読み出しは禁止です'
fi
if echo "$CLEAN" | grep -qE "(^|[/[:space:]\"'])\.env(\.[A-Za-z0-9._-]+)?${BOUND}"; then
  block '.env ファイルの読み出しは禁止です (.env.example 系のみ可)'
fi
if echo "$CLEAN" | grep -qE "\.pem${BOUND}|id_(rsa|ed25519|ecdsa|dsa)${BOUND}|/\.netrc${BOUND}|secrets/global\.env${BOUND}"; then
  block '秘密鍵・認証情報ファイルの読み出しは禁止です'
fi

exit 0
