# orphan-reaper

English | [日本語](#日本語)

At session start, cleans up development processes left behind by finished sessions (dev servers, test workers, browser automation, and so on).

- **Clean up** (`reap-orphans.py`): stops only orphans whose launching session has ended. Processes listening on a port are not stopped; it only suggests whether to stop them.
- **Notify** (`orphan-cpu-notice.sh`): if a development process keeps using CPU after its parent ended, it hands the list and the commands to stop them to the agent, which suggests them to you. It never kills them itself.

## Install

```text
/plugin marketplace add yasuguin/skills
/plugin install orphan-reaper@yasuguin
```

Requires `uv`. Cleanup works on macOS only (it reads the orphans' environment variables through a macOS mechanism; on Linux it stops nothing). The CPU notice works on both macOS and Linux.

## 日本語

セッションの開始時に、終わったセッションが置き去りにした開発用のプロセス（dev server、テストのワーカー、ブラウザの自動操作など）を片付けます。

- **片付ける**（`reap-orphans.py`）: 起動したセッションが終わっている孤児だけを止めます。ポートを待ち受けているものは止めず、止めてよいかの提案だけを出します。
- **知らせる**（`orphan-cpu-notice.sh`）: 親が終わったまま CPU を使い続けている開発用プロセスがあれば、一覧と止めるコマンドをエージェントに渡して、ユーザーに提案させます。自分では kill しません。

### 入れ方

```text
/plugin marketplace add yasuguin/skills
/plugin install orphan-reaper@yasuguin
```

`uv` が要ります。片付けは macOS だけで動きます（孤児の環境変数を macOS の仕組みで読むため。Linux では何も止めません）。CPU の通知は macOS と Linux の両方で動きます。
