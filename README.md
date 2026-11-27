# skills

English | [日本語](README.ja.md)

[![skills.sh](https://skills.sh/b/yasuguin/skills)](https://skills.sh/yasuguin/skills)

Skills I grew while building software every day with AI agents (mostly Claude Code). Each one started as a problem I solved mechanically, one at a time, and was then reshaped to work in other people's environments too.

The skill bodies are written in Japanese. Agents read them fine, and they answer in whatever language you use.

## Install

```bash
npx skills@latest add yasuguin/skills
```

Pick a single skill with `--skill`:

```bash
npx skills@latest add yasuguin/skills --skill grill-visual
```

## Skills

- **[agent-doctor](skills/agent-doctor)**: Diagnoses your AI agent setup (Claude Code and Codex) from three sides, traces each problem down to the rule that causes it, and fixes only what you approve. The main one is rule optimization: it takes stock of rules written as prose in instruction files and skills, and moves them into mechanical enforcement (settings, hooks, agent definitions, Codex rules and profiles, lint, tests), removes duplicates, and fixes gaps between what is written and what is enforced. Speed diagnosis finds why development is slow from conversation logs and per-hook measurements. Cost diagnosis converts your usage into API list prices and finds what pushes the cost up (subagent types, projects, sessions, cache reads). Requires Python (`uv`). If you also want a weekly automatic report, install the [agent-doctor plugin](plugins/agent-doctor) instead, which bundles this skill (installing both gives you the skill twice).
- **[agent-orchestrate](skills/agent-orchestrate)**: Delegates implementation to codex, claude, or pi running in tmux (or Herdr) panes, and repeats review of their completion reports and re-requests until the goal is met. Also covers delivering messages to a pane reliably (separate Enter, delivery confirmation, scheduled sends).
- **[ask-me](skills/ask-me)**: When the agent sends back its questions as one long block of text, it makes the agent split them into question cards, one decision per question, so you can answer by picking instead of reading everything and composing a reply.
- **[ban-rule-manager](skills/ban-rule-manager)**: Instead of asking in prose that something "is not to be used", it blocks it with a Claude Code PreToolUse hook. You only write the ban into a JSON registry; the hook engine is bundled. Also includes a script that scans code written before the hook existed, or by other agents. Requires `jq` and `perl`.
- **[cli-creator](skills/cli-creator)**: When building or fixing a CLI, it aligns the command structure, `--help` examples, `--json`, failure hints and exit codes, and tests so the CLI is easy for both agents and people.
- **[code-as-spec](skills/code-as-spec)**: Develop with code, tests, types, and why-comments near the code as the source of truth, instead of spec documents. The mindset and steps for when you want to stop keeping spec docs in sync.
- **[grill-visual](skills/grill-visual)**: When a question comes up mid-grilling that is faster to answer by looking than by reading (mockups, layout comparisons, navigation structure, state diagrams), it lays the options out in a localhost browser tab and lets you pick by clicking. Your choice, notes on options, comments on elements, and slider tweaks become the instruction to the agent as-is. Runs on Node's standard library only and makes no external requests.
- **[just-ask](skills/just-ask)**: A read-only mode that answers without editing. When you say "just investigate first" or "don't start yet", it checks the facts and answers briefly.
- **[skill-kaizen](skills/skill-kaizen)**: Spots when an existing skill should be refined, from feedback and repeated corrections in the conversation, and fixes it. It does not just append; it also removes duplication and stale text.
- **[test-human-walkthrough](skills/test-human-walkthrough)**: Exploratory testing as a fictional user: it operates a web app (claude-in-chrome) or a macOS app one action at a time and reports what felt off, with reasons and evidence.

## Plugins (Claude Code hooks)

Hooks ship as Claude Code plugins. Installing one registers its hooks, and you can remove them by removing the plugin.

```text
/plugin marketplace add yasuguin/skills
/plugin install safety-guard@yasuguin
```

- **[agent-doctor](plugins/agent-doctor)**: The agent-doctor skill plus a weekly automatic report.
- **[gcloud-readonly](plugins/gcloud-readonly)**: Lets `gcloud` commands that are judged read-only through without confirmation.
- **[orphan-reaper](plugins/orphan-reaper)**: Cleans up dev servers and test workers left behind by finished sessions, and tells you about orphans still burning CPU.
- **[push-guard](plugins/push-guard)**: Lets `git push` to the default branch and `gh` writes through without confirmation only for your own repos on an allowlist. Prevents accidents such as opening an issue on someone else's public repo through a fork.
- **[safety-guard](plugins/safety-guard)**: Sends dangerous commands (`rm -rf`, destructive `git checkout`, deleting branches other than your working branch) to confirmation, and blocks reading `~/.ssh` keys and `.env`. Words that merely appear in a commit message or a grep pattern do not trigger it.
- **[zundamon-notify](plugins/zundamon-notify)**: Announces completion and waiting-for-input in the voice of VOICEVOX Zundamon.

Hooks inside a plugin cannot be removed one by one, so plugins are split by purpose.

## Acknowledgements

Some skills call skills from [mattpocock/skills](https://github.com/mattpocock/skills) (by Matt Pocock) and [anthropics/skills](https://github.com/anthropics/skills) by name. What each skill calls and how to install it is listed under "前提にしている skill" (prerequisite skills) in its SKILL.md. grill-visual and ask-me in particular could stay small only because of the `grilling` approach of narrowing things down one question at a time, each with a recommendation.

## License

[MIT](LICENSE)
