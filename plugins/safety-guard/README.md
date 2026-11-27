# safety-guard

English | [日本語](#日本語)

Watches the commands Claude Code runs and the files it reads, with PreToolUse hooks.

- **Send dangerous commands to confirmation** (`validate-bash.sh`): `rm -r` / `rm -f`, `git rm -f`, `chmod` that lets other users write, deleting remote branches other than your working branch, and so on. Deletions you can restore from git (tracked files only, `/tmp`, build output) are not asked about. To avoid stopping on words that merely appear in a commit message or a grep pattern, it strips quoted strings and heredoc bodies before judging (`strip-shell-literals.pl`).
- **Decide which branches may be cleaned up** (`git-cleanup-policy.py`): records only branches created in the session, and branches already pushed and merged, as safe to delete.
- **Block reading secrets** (`validate-secret-access.sh`): keys in `~/.ssh`, `.env`, cloud credential files, and so on.

## Install

```text
/plugin marketplace add yasuguin/skills
/plugin install safety-guard@yasuguin
```

Requires `jq`, `perl`, and `uv`.

## 日本語

Claude Code が打つコマンドとファイルの読み出しを、PreToolUse の hook で見張ります。

- **危ないコマンドは確認に回す**（`validate-bash.sh`）: `rm -r` / `rm -f`、`git rm -f`、他ユーザーに書き込みを許す `chmod`、作業ブランチ以外のリモートブランチ削除など。git から戻せる削除（追跡ファイルだけ、`/tmp`・生成物の削除）は聞きません。commit メッセージや grep の検索語に書いただけの語では止まらないよう、引用符の中身と heredoc の本文を除いてから判定します（`strip-shell-literals.pl`）。
- **作ったブランチの後片付けを許す範囲を決める**（`git-cleanup-policy.py`）: そのセッションで作ったブランチと、push・取り込み済みのブランチだけを削除してよいものとして記録します。
- **秘密情報の読み出しを止める**（`validate-secret-access.sh`）: `~/.ssh` の鍵、`.env`、クラウドの認証ファイルなど。

### 入れ方

```text
/plugin marketplace add yasuguin/skills
/plugin install safety-guard@yasuguin
```

`jq`・`perl`・`uv` が要ります。
