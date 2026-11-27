# agent-doctor

English | [日本語](#日本語)

A plugin that adds a weekly automatic report to the [agent-doctor](../../skills/agent-doctor) skill. At session start, if 7 days have passed since the last report, it aggregates in the background, and if it finds an anomaly slowing development down, it tells you once in the next session.

If you only want the skill, `npx skills@latest add yasuguin/skills --skill agent-doctor` also works. Installing both gives you the skill twice, so pick one.

## Install

```text
/plugin marketplace add yasuguin/skills
/plugin install agent-doctor@yasuguin
```

Requires `uv`.

## 日本語

[agent-doctor](../../skills/agent-doctor) の skill に、週 1 回の自動集計を足した plugin です。セッションの開始時に、前回の集計から 7 日経っていれば裏で集計し、開発を遅くしている異常が見つかれば次のセッションで 1 回だけ知らせます。

skill だけなら `npx skills@latest add yasuguin/skills --skill agent-doctor` でも入ります。両方入れると skill が 2 つになるので、どちらか一方にしてください。

### 入れ方

```text
/plugin marketplace add yasuguin/skills
/plugin install agent-doctor@yasuguin
```

`uv` が要ります。
