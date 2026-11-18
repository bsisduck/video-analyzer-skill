#!/usr/bin/env bash
# Video Information Script - metadata and analysis plan for tier selection
# Usage: video-info.sh <input_video> [fps_override] [start_time] [end_time]
# Example: video-info.sh video.mp4 5 10 30
# Outputs JSON: stream selection, tier, fps, grid layout, subtitles, work dir.
# Pass "" for fps_override to keep the tier default while setting a time range.

set -euo pipefail

[[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && export PATH="$HOME/bin:$PATH"

: "${1:?Usage: video-info.sh <input_video> [fps_override] [start_time] [end_time]}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$1" ]] || { echo "ERROR: File not found: $1" >&2; exit 1; }
# Absolute path: a relative name like "12:30 talk.mp4" or "-clip.mp4" would
# otherwise be read as a protocol or an option.
INPUT="$(cd "$(dirname -- "$1")" && pwd)/$(basename -- "$1")"

exec python3 "$SCRIPT_DIR/vahelper.py" info "$INPUT" "${2:-}" "${3:-}" "${4:-}"
