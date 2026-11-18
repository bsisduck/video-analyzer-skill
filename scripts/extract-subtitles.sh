#!/usr/bin/env bash
# Embedded Subtitle Extraction Script
# Usage: extract-subtitles.sh <input_video> <output_dir> [subtitle_index]
# Example: extract-subtitles.sh video.mkv /tmp/subs 0
# subtitle_index: position among the file's subtitle streams, as reported in
#                 "subtitle_streams[].subtitle_index" by video-info.sh (default: 0)
# Writes <output_dir>/subtitles.srt. Existing subtitles are faster and usually
# more accurate than transcribing the audio again.

set -euo pipefail

[[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && export PATH="$HOME/bin:$PATH"

INPUT="${1:?Usage: extract-subtitles.sh <input_video> <output_dir> [subtitle_index]}"
OUTPUT_DIR="${2:?Specify output directory}"
SUB_INDEX="${3:-0}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$INPUT" ]] || fail "File not found: $INPUT"
[[ "$SUB_INDEX" =~ ^[0-9]+$ ]] || fail "subtitle_index must be a whole number, got: $SUB_INDEX"

INPUT="$(cd "$(dirname -- "$INPUT")" && pwd)/$(basename -- "$INPUT")"
mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
SUB_FILE="${OUTPUT_DIR}/subtitles.srt"
rm -f "$SUB_FILE"

CODEC=$(ffprobe -v error -select_streams "s:${SUB_INDEX}" -show_entries stream=codec_name -of csv=p=0 "$INPUT" 2>/dev/null | head -n 1)
[[ -n "$CODEC" ]] || fail "No subtitle stream at index $SUB_INDEX in $INPUT"

case "$CODEC" in
    subrip|srt|ass|ssa|mov_text|webvtt|text) ;;
    *) fail "Subtitle stream $SUB_INDEX is '$CODEC', an image-based format that cannot be read as text" ;;
esac

ffmpeg -nostdin -hide_banner -loglevel error -y \
    -i "$INPUT" -map "0:s:${SUB_INDEX}" -c:s srt "$SUB_FILE"

[[ -s "$SUB_FILE" ]] || fail "Subtitle stream $SUB_INDEX produced no text"

echo "Subtitles: $SUB_FILE ($(grep -c -- '-->' "$SUB_FILE" || true) cues, source codec: $CODEC)"
