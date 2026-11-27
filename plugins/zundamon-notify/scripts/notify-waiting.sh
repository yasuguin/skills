#!/bin/bash
# Claude Code Notification hook - 入力待ち
# VOICEVOX (ずんだもん) が起動していればずんだもん音声、なければ Glass音にフォールバック

# play-sound.sh はこの script と同じディレクトリに置く。
source "$(dirname "$0")/play-sound.sh"
# 鳴らす音は CLAUDE_NOTIFY_SOUND で変えられる。無ければ macOS の標準の音にする。
SOUND="${CLAUDE_NOTIFY_SOUND:-$HOME/.config/sounds/notify.mp3}"
[[ -f "$SOUND" ]] || SOUND="/System/Library/Sounds/Glass.aiff"

PROJECT_NAME=$(basename "$PWD")
TEXT="${PROJECT_NAME}、入力待ちなのだ"

VOICEVOX_URL="http://127.0.0.1:50021"
SPEAKER=3  # ずんだもん (ノーマル)

if ! curl -sf "${VOICEVOX_URL}/version" > /dev/null 2>&1; then
  play_sound "$SOUND"
  exit 0
fi

TEXT_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$TEXT")
QUERY=$(curl -sf -X POST "${VOICEVOX_URL}/audio_query?text=${TEXT_ENCODED}&speaker=${SPEAKER}")

if [[ -z "$QUERY" ]]; then
  play_sound "$SOUND"
  exit 0
fi

TMPFILE=$(mktemp /tmp/voicevox_XXXXXX.wav)
curl -sf -X POST "${VOICEVOX_URL}/synthesis?speaker=${SPEAKER}" \
  -H "Content-Type: application/json" \
  -d "$QUERY" \
  -o "$TMPFILE"

play_sound "$TMPFILE"
rm -f "$TMPFILE"
