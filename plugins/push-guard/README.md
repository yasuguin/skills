# push-guard

English | [日本語](#日本語)

Lets `git push` to the default branch (main, master, and so on) and `gh` writes such as issues, PRs, and releases through without confirmation only when they are on an allowlist. Everything else goes to Claude Code's confirmation.

- Pushes to working branches (anything other than the default branch) pass even if not on the allowlist.
- `gh` writes pass only when the target repo can be determined by `-R`, `gh repo set-default`, or there being exactly one remote, and its owner is on the allowlist. This prevents accidents such as forgetting `-R` in a fork and opening an issue on someone else's public repo.

## Allowlists

One entry per line in each. If a file is missing, everything goes to confirmation.

- `~/.claude/push-allowlist.txt`: `owner/repo` you may push to without confirmation (`owner/*` for a whole owner)
- `~/.claude/gh-write-owners.txt`: your own owners (GitHub user and organization names)

Change the locations with the `PUSH_ALLOWLIST` and `GH_WRITE_OWNERS` environment variables.

## Install

```text
/plugin marketplace add yasuguin/skills
/plugin install push-guard@yasuguin
```

Requires `jq`, `perl`, and `git`.

## 日本語

既定ブランチ（main・master など）への `git push` と、`gh` での issue・PR・release などの書き込みを、許可リストにあるときだけ確認なしで通します。それ以外は Claude Code がユーザーに確認します。

- 作業ブランチ（既定ブランチ以外）への push は、許可リストに無くても通します。
- `gh` の書き込みは、向き先の repo を `-R`・`gh repo set-default`・remote が 1 つだけ、のどれかで決められて、その owner が許可リストにあるときだけ通します。fork で `-R` を付け忘れて、他人の公開 repo に issue を作ってしまう事故を防ぎます。

## 許可リスト

どちらも 1 行に 1 つ書きます。ファイルが無ければ、どれも確認に回ります。

- `~/.claude/push-allowlist.txt`: 確認なしで push してよい `owner/repo`（`owner/*` で owner ごと）
- `~/.claude/gh-write-owners.txt`: 自分の owner（GitHub のユーザー名・組織名）

置き場所は環境変数 `PUSH_ALLOWLIST`・`GH_WRITE_OWNERS` で変えられます。

### 入れ方

```text
/plugin marketplace add yasuguin/skills
/plugin install push-guard@yasuguin
```

`jq`・`perl`・`git` が要ります。
