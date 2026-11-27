# macOS は afplay、Linux/WSL2 は ffplay (PulseAudio 経由) で再生する。
# afplay は macOS 専用で WSL2 には存在しないため、フォールバック音が鳴らない不具合があった。
# aplay は WSL2 に ALSA サウンドカードが存在せず "no soundcards found" で必ず失敗するため使わない。
# mp3/wav とも ffplay --enable-libpulse ビルドが PulseAudio (WSLg の RDPSink) 経由で再生できる。
play_sound() {
  local file="$1"
  if command -v afplay > /dev/null 2>&1; then
    afplay "$file"
    return
  fi
  ffplay -nodisp -autoexit -loglevel quiet "$file" > /dev/null 2>&1
}
