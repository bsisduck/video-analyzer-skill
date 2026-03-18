#!/usr/bin/env bash
# Video Information Script - Get all metadata for tier selection
# Usage: video-info.sh <input_video>
# Outputs JSON with duration, resolution, codec, fps, audio info
# Auto-detects the correct video stream (skips attached_pic/thumbnails)

set -euo pipefail

INPUT="${1:?Usage: video-info.sh <input_video>}"

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: File not found: $INPUT" >&2
    exit 1
fi

# Get full probe data
PROBE=$(ffprobe -v error -show_format -show_streams -of json "$INPUT" 2>/dev/null)

# Auto-detect the correct video stream index (skip attached_pic/thumbnail streams)
# attached_pic streams have disposition.attached_pic=1 and are typically MJPEG
VIDEO_STREAM_INDEX=$(echo "$PROBE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('streams', []):
    if s.get('codec_type') == 'video':
        disp = s.get('disposition', {})
        # Skip attached_pic (thumbnails), still_image streams
        if disp.get('attached_pic', 0) == 1:
            continue
        if disp.get('still_image', 0) == 1:
            continue
        # Skip MJPEG streams that look like thumbnails (no frame rate info)
        if s.get('codec_name') == 'mjpeg' and s.get('avg_frame_rate') == '0/0':
            continue
        print(s.get('index', 0))
        break
else:
    # Fallback: use first video stream
    for s in d.get('streams', []):
        if s.get('codec_type') == 'video':
            print(s.get('index', 0))
            break
" 2>/dev/null || echo "0")

# Check if audio stream exists
HAS_AUDIO=$(echo "$PROBE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('streams', []):
    if s.get('codec_type') == 'audio':
        print('true')
        break
else:
    print('false')
" 2>/dev/null || echo "false")

# Get video stream details using the correct stream index
VIDEO_INFO=$(echo "$PROBE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
idx = int(sys.argv[1])
for s in d.get('streams', []):
    if s.get('index') == idx:
        w = s.get('width', 0)
        h = s.get('height', 0)
        codec = s.get('codec_name', 'unknown')
        fps_str = s.get('r_frame_rate', '0/1')
        # Calculate fps from fraction
        parts = fps_str.split('/')
        fps = float(parts[0]) / float(parts[1]) if len(parts) == 2 and float(parts[1]) != 0 else 0
        orientation = 'portrait' if h > w else ('landscape' if w > h else 'square')
        print(f'{w},{h},{codec},{fps:.2f},{orientation}')
        break
" "$VIDEO_STREAM_INDEX" 2>/dev/null || echo "0,0,unknown,0,unknown")

IFS=',' read -r WIDTH HEIGHT CODEC SOURCE_FPS ORIENTATION <<< "$VIDEO_INFO"

# Extract duration
DURATION=$(echo "$PROBE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['format'].get('duration','0'))" 2>/dev/null || echo "0")
DURATION_INT=$(echo "$DURATION" | cut -d. -f1)
FILESIZE=$(echo "$PROBE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['format'].get('size','0'))" 2>/dev/null || echo "0")

# Determine analysis tier
if [[ "$DURATION_INT" -le 60 ]]; then
    TIER="short"
    FPS_RATE="2"
    WHISPER_MODEL="medium"
    DESCRIPTION="Under 1min: 2 frames/sec, detailed visual+audio analysis"
elif [[ "$DURATION_INT" -le 180 ]]; then
    TIER="medium"
    FPS_RATE="1"
    WHISPER_MODEL="medium"
    DESCRIPTION="1-3min: 1 frame/sec, detailed analysis with transcription"
elif [[ "$DURATION_INT" -le 600 ]]; then
    TIER="long"
    FPS_RATE="0.1"
    WHISPER_MODEL="base"
    DESCRIPTION="3-10min: 1 frame/10sec, transcription-focused analysis"
else
    TIER="extended"
    FPS_RATE="0.05"
    WHISPER_MODEL="base"
    DESCRIPTION="10min+: 1 frame/20sec (capped), transcription-focused"
fi

# Calculate expected frames
EXPECTED_FRAMES=$(echo "$DURATION * $FPS_RATE" | bc -l 2>/dev/null | cut -d. -f1)

# Cap extended tier at ~60 frames
MAX_FRAMES=0
if [[ "$TIER" == "extended" && "$EXPECTED_FRAMES" -gt 60 ]]; then
    MAX_FRAMES=60
fi

# Determine grid layout based on orientation
# Portrait videos: use 3x5 grid (3 cols, 5 rows = 15 frames) for better cell visibility
# Landscape/square: use 4x4 grid (16 frames)
if [[ "$ORIENTATION" == "portrait" ]]; then
    GRID_LAYOUT="3x5"
    FRAMES_PER_GRID=15
else
    GRID_LAYOUT="4x4"
    FRAMES_PER_GRID=16
fi

# Generate work directory name
BASENAME=$(basename "$INPUT" | sed 's/\.[^.]*$//')
WORK_DIR="/tmp/video-analysis-${BASENAME}"

# Format duration as HH:MM:SS
FORMATTED=$(printf '%02d:%02d:%02d' $((DURATION_INT/3600)) $(( (DURATION_INT%3600)/60 )) $((DURATION_INT%60)))

cat <<EOF
{
  "file": "$(basename "$INPUT")",
  "path": "$INPUT",
  "duration_seconds": $DURATION,
  "duration_formatted": "$FORMATTED",
  "filesize_bytes": $FILESIZE,
  "width": $WIDTH,
  "height": $HEIGHT,
  "codec": "$CODEC",
  "source_fps": $SOURCE_FPS,
  "orientation": "$ORIENTATION",
  "has_audio": $HAS_AUDIO,
  "video_stream_index": $VIDEO_STREAM_INDEX,
  "tier": "$TIER",
  "tier_description": "$DESCRIPTION",
  "fps_rate": $FPS_RATE,
  "expected_frames": ${EXPECTED_FRAMES:-0},
  "max_frames": $MAX_FRAMES,
  "whisper_model": "$WHISPER_MODEL",
  "grid_layout": "$GRID_LAYOUT",
  "frames_per_grid": $FRAMES_PER_GRID,
  "work_dir": "$WORK_DIR"
}
EOF
