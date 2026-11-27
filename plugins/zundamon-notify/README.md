# zundamon-notify

English | [日本語](#日本語)

Announces task completion and waiting-for-input in the voice of Zundamon from [VOICEVOX](https://voicevox.hiroshiba.jp/): 「<project name>、完了なのだ」 (done) and 「<project name>、入力待ちなのだ」 (waiting for input).

- If VOICEVOX is not running, it launches it at session start (when `/Applications/VOICEVOX.app` exists).
- Without VOICEVOX, it plays a notification sound instead. Change the sound with the `CLAUDE_NOTIFY_SOUND` environment variable; the default is macOS `Glass.aiff`.
- Synthesis and playback run in the background, so the agent never waits.

Voice: VOICEVOX:ずんだもん. Follow the terms of use of VOICEVOX and Zundamon.

## Install

```text
/plugin marketplace add yasuguin/skills
/plugin install zundamon-notify@yasuguin
```

For macOS (plays with `afplay`, or `ffplay` if unavailable).

## 日本語

作業の完了と入力待ちを、[VOICEVOX](https://voicevox.hiroshiba.jp/) のずんだもんの声で知らせます。「<プロジェクト名>、完了なのだ」「<プロジェクト名>、入力待ちなのだ」。

- VOICEVOX が起動していなければ、セッションの開始時に起動します（`/Applications/VOICEVOX.app` がある場合）。
- VOICEVOX が無いときは通知音を鳴らします。音は環境変数 `CLAUDE_NOTIFY_SOUND` で変えられ、既定は macOS の `Glass.aiff` です。
- 声の合成と再生は裏で行うので、エージェントを待たせません。

音声は VOICEVOX:ずんだもん です。VOICEVOX とずんだもんの利用規約に従ってください。

### 入れ方

```text
/plugin marketplace add yasuguin/skills
/plugin install zundamon-notify@yasuguin
```

macOS 向けです（再生に `afplay`、無ければ `ffplay` を使います）。
