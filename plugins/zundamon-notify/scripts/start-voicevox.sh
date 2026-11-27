#!/bin/bash
# Claude Code SessionStart hook - VOICEVOX自動起動
# VOICEVOXが未起動であれば起動する

VOICEVOX_URL="http://127.0.0.1:50021"
VOICEVOX_APP="/Applications/VOICEVOX.app"

# すでにAPIが応答していれば何もしない
if curl -sf "${VOICEVOX_URL}/version" > /dev/null 2>&1; then
  exit 0
fi

# アプリが存在しなければスキップ
if [[ ! -d "$VOICEVOX_APP" ]]; then
  exit 0
fi

# バックグラウンドで起動
open -a VOICEVOX
