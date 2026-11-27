# gcloud-readonly

English | [日本語](#日本語)

Lets `gcloud` commands that can be mechanically judged read-only (`list`, `describe`, `get-iam-policy`, and so on) through without confirmation. Writes, and commands written in a way it cannot judge, are left alone and go to Claude Code's confirmation as before.

## Install

```text
/plugin marketplace add yasuguin/skills
/plugin install gcloud-readonly@yasuguin
```

Requires `uv`.

## 日本語

`gcloud` のコマンドのうち、読み取りだけと機械的に判定できたもの（`list`・`describe`・`get-iam-policy` など）を確認なしで通します。書き込みや、判定できない書き方のものは何もせず、今までどおり Claude Code の確認に回ります。

### 入れ方

```text
/plugin marketplace add yasuguin/skills
/plugin install gcloud-readonly@yasuguin
```

`uv` が要ります。
