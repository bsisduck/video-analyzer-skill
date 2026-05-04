#!/usr/bin/env bash
# Video Frame Extraction Script
# Usage: extract-frames.sh <input_video> <output_dir> <fps_rate> [max_frames] [stream_index] [grid_layout]
# Example: extract-frames.sh video.mp4 /tmp/frames 2 0 1 4x4
# fps_rate examples: 2 (2/sec), 1 (1/sec), 0.1 (1/10sec), 0.05 (1/20sec)
# stream_index: video stream index (default: auto-detect, skipping thumbnails)
# grid_layout: tile layout for montage grids (default: 4x4)

set -euo pipefail

[[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && export PATH="$HOME/bin:$PATH"

INPUT="${1:?Usage: extract-frames.sh <input_video> <output_dir> <fps_rate> [max_frames] [stream_index] [grid_layout] [start_time] [end_time]}"
OUTPUT_DIR="${2:?Specify output directory}"
FPS="${3:?Specify fps rate (e.g., 2, 1, 0.1, 0.05)}"
MAX_FRAMES="${4:-0}"  # 0 = auto safety cap
STREAM_INDEX="${5:-auto}"  # auto = detect correct stream
GRID_LAYOUT="${6:-4x4}"  # tile layout for grids
START_TIME="${7:-}"  # e.g., "00:00:10" or "10" (seconds)
END_TIME="${8:-}"    # e.g., "00:00:30" or "30" (seconds)

MAX_FPS=120
MAX_FRAME_CAP=1000
MAX_GRID_DIM=10
MAX_GRID_CELLS=100

is_positive_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v n="$1" 'BEGIN { exit !(n > 0) }'
}

number_lte() {
    awk -v n="$1" -v max="$2" 'BEGIN { exit !(n <= max) }'
}

is_time_value() {
    [[ "$1" =~ ^[0-9]+$ || "$1" =~ ^[0-9]+:[0-5]?[0-9]$ || "$1" =~ ^[0-9]+:[0-5]?[0-9]:[0-5]?[0-9]$ ]]
}

time_to_seconds() {
    local value="$1"
    local first second third
    IFS=: read -r first second third <<< "$value"

    if [[ -z "${second:-}" ]]; then
        echo "$((10#$first))"
    elif [[ -z "${third:-}" ]]; then
        echo "$((10#$first * 60 + 10#$second))"
    else
        echo "$((10#$first * 3600 + 10#$second * 60 + 10#$third))"
    fi
}

# Validate input
if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: File not found: $INPUT" >&2
    exit 1
fi

if ! is_positive_number "$FPS" || ! number_lte "$FPS" "$MAX_FPS"; then
    echo "ERROR: fps rate must be > 0 and <= ${MAX_FPS}: $FPS" >&2
    exit 1
fi

if ! [[ "$MAX_FRAMES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: max_frames must be a non-negative integer: $MAX_FRAMES" >&2
    exit 1
fi
if [[ "$MAX_FRAMES" -gt "$MAX_FRAME_CAP" ]]; then
    echo "ERROR: max_frames must be 0 or <= ${MAX_FRAME_CAP}: $MAX_FRAMES" >&2
    exit 1
fi

if [[ "$STREAM_INDEX" != "auto" ]] && ! [[ "$STREAM_INDEX" =~ ^[0-9]+$ ]]; then
    echo "ERROR: stream_index must be 'auto' or a non-negative integer: $STREAM_INDEX" >&2
    exit 1
fi

if ! [[ "$GRID_LAYOUT" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
    echo "ERROR: grid_layout must match NxM (e.g., 4x4): $GRID_LAYOUT" >&2
    exit 1
fi
GRID_COLS="${GRID_LAYOUT%x*}"
GRID_ROWS="${GRID_LAYOUT#*x}"
GRID_CELLS=$((GRID_COLS * GRID_ROWS))
if [[ "$GRID_COLS" -gt "$MAX_GRID_DIM" || "$GRID_ROWS" -gt "$MAX_GRID_DIM" || "$GRID_CELLS" -gt "$MAX_GRID_CELLS" ]]; then
    echo "ERROR: grid_layout must be at most ${MAX_GRID_DIM}x${MAX_GRID_DIM} and <= ${MAX_GRID_CELLS} cells: $GRID_LAYOUT" >&2
    exit 1
fi

if [[ -n "$START_TIME" ]] && ! is_time_value "$START_TIME"; then
    echo "ERROR: Invalid start_time format: $START_TIME" >&2
    exit 1
fi

if [[ -n "$END_TIME" ]] && ! is_time_value "$END_TIME"; then
    echo "ERROR: Invalid end_time format: $END_TIME" >&2
    exit 1
fi
START_SECONDS=0
if [[ -n "$START_TIME" ]]; then
    START_SECONDS=$(time_to_seconds "$START_TIME")
fi
END_SECONDS=""
if [[ -n "$END_TIME" ]]; then
    END_SECONDS=$(time_to_seconds "$END_TIME")
fi
if [[ -n "$END_SECONDS" && "$END_SECONDS" -le "$START_SECONDS" ]]; then
    echo "ERROR: end_time must be greater than start_time" >&2
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Auto-detect video stream if not specified
if [[ "$STREAM_INDEX" == "auto" ]]; then
    STREAM_INDEX=$(ffprobe -v error -show_streams -of json "$INPUT" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('streams', []):
    if s.get('codec_type') == 'video':
        disp = s.get('disposition', {})
        if disp.get('attached_pic', 0) == 1:
            continue
        if s.get('codec_name') == 'mjpeg' and s.get('avg_frame_rate') == '0/0':
            continue
        print(s.get('index', 0))
        break
else:
    for s in d.get('streams', []):
        if s.get('codec_type') == 'video':
            print(s.get('index', 0))
            break
" 2>/dev/null || echo "0")
fi

# Build the -map argument to select the correct video stream
MAP_ARGS=("-map" "0:${STREAM_INDEX}")
TIME_ARGS=()
if [[ -n "$START_TIME" ]]; then
    TIME_ARGS+=("-ss" "$START_TIME")
fi
if [[ -n "$END_TIME" ]]; then
    TIME_ARGS+=("-to" "$END_TIME")
fi

# Get video info from the correct stream
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" 2>/dev/null)
RESOLUTION=$(ffprobe -v error -select_streams v:${STREAM_INDEX} -show_entries stream=width,height -of csv=p=0 "$INPUT" 2>/dev/null || echo "unknown")
TOTAL_FRAMES=$(python3 -c "print(int(float('$DURATION') * float('$FPS')))" 2>/dev/null)

echo "=== Video Frame Extraction ==="
echo "Input: $INPUT"
echo "Duration: ${DURATION}s"
echo "Resolution: $RESOLUTION"
echo "Video stream: $STREAM_INDEX"
echo "FPS rate: $FPS"
echo "Grid layout: $GRID_LAYOUT"
echo "Estimated frames: $TOTAL_FRAMES"
echo "Output: $OUTPUT_DIR"
echo ""

# Build FFmpeg filter - resize to max 1280px wide, burn timestamp
FILTER="fps=${FPS},scale='min(1280,iw)':-2,drawtext=text='%{pts\\:hms}':x=10:y=10:fontsize=28:fontcolor=white:borderw=2:bordercolor=black"

# Add frame limit if specified
EFFECTIVE_FRAME_LIMIT="$MAX_FRAMES"
if [[ "$EFFECTIVE_FRAME_LIMIT" -eq 0 ]]; then
    EFFECTIVE_FRAME_LIMIT="$MAX_FRAME_CAP"
fi
FRAME_LIMIT_ARGS=("-frames:v" "$EFFECTIVE_FRAME_LIMIT")
MONTAGE_LIMIT=$(((EFFECTIVE_FRAME_LIMIT + GRID_CELLS - 1) / GRID_CELLS))
MONTAGE_LIMIT_ARGS=("-frames:v" "$MONTAGE_LIMIT")
echo "Frame limit: $EFFECTIVE_FRAME_LIMIT"

# Extract individual frames as JPG
ffmpeg -i "$INPUT" \
    "${MAP_ARGS[@]}" \
    "${TIME_ARGS[@]}" \
    -vf "$FILTER" \
    -q:v 2 \
    "${FRAME_LIMIT_ARGS[@]}" \
    "${OUTPUT_DIR}/frame_%05d.jpg" \
    -y -loglevel warning 2>&1

EXTRACTED=$(ls "${OUTPUT_DIR}"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "Extracted: $EXTRACTED frames"

# Generate montage grids
echo ""
echo "=== Creating Montage Grids ==="

# Determine grid cell size based on orientation
# Parse grid layout to determine if portrait-optimized
GRID_CELL_WIDTH=640
MONTAGE_FILTER="fps=${FPS},scale='min(${GRID_CELL_WIDTH},iw)':-2,drawtext=text='%{pts\\:hms}':x=5:y=5:fontsize=16:fontcolor=white:borderw=1:bordercolor=black,tile=${GRID_LAYOUT}"

ffmpeg -i "$INPUT" \
    "${MAP_ARGS[@]}" \
    "${TIME_ARGS[@]}" \
    -vf "$MONTAGE_FILTER" \
    -q:v 2 \
    "${MONTAGE_LIMIT_ARGS[@]}" \
    "${OUTPUT_DIR}/grid_%03d.jpg" \
    -y -loglevel warning 2>&1

GRIDS=$(ls "${OUTPUT_DIR}"/grid_*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "Created: $GRIDS montage grids (${GRID_LAYOUT})"

# Detect scene changes (key moments)
echo ""
echo "=== Scene Change Detection ==="
SCENE_FILE="${OUTPUT_DIR}/scene_changes.txt"
ffmpeg -i "$INPUT" \
    "${MAP_ARGS[@]}" \
    "${TIME_ARGS[@]}" \
    -vf "select='gt(scene,0.3)',showinfo" \
    -f null - 2>&1 | grep 'pts_time' | sed 's/.*pts_time:\([0-9.]*\).*/\1/' | grep '^[0-9]' > "$SCENE_FILE" || true

SCENE_COUNT=$(wc -l < "$SCENE_FILE" | tr -d ' ')
echo "Detected: $SCENE_COUNT scene changes"

# Extract key frames at scene changes (high-res individual frames for detailed analysis)
# Cap at 20 key frames to avoid excessive extraction
if [[ "$SCENE_COUNT" -gt 0 ]]; then
    mkdir -p "${OUTPUT_DIR}/key_frames"
    KEY_IDX=0
    while IFS= read -r TIMESTAMP; do
        KEY_IDX=$((KEY_IDX + 1))
        [[ "$KEY_IDX" -gt 20 ]] && break
        # Format timestamp for filename (replace . with _)
        TS_SAFE=$(echo "$TIMESTAMP" | tr '.' '_')
        OUTFILE="${OUTPUT_DIR}/key_frames/scene_$(printf '%02d' $KEY_IDX)_${TS_SAFE}s.jpg"
        ffmpeg -i "$INPUT" \
            "${MAP_ARGS[@]}" \
            -ss "$TIMESTAMP" \
            -frames:v 1 \
            -vf "scale='min(1280,iw)':-2,drawtext=text='${TIMESTAMP}s':x=10:y=10:fontsize=32:fontcolor=white:borderw=2:bordercolor=black" \
            -q:v 1 \
            -update 1 \
            "$OUTFILE" \
            -y -loglevel warning 2>&1
    done < "$SCENE_FILE"
    KEY_EXTRACTED=$(ls "${OUTPUT_DIR}"/key_frames/scene_*.jpg 2>/dev/null | wc -l | tr -d ' ')
    echo "Extracted: $KEY_EXTRACTED key frames at scene changes"
fi

# Write metadata file
cat > "${OUTPUT_DIR}/metadata.json" <<METAEOF
{
  "source": "$(basename "$INPUT")",
  "duration_seconds": $DURATION,
  "resolution": "$RESOLUTION",
  "video_stream_index": $STREAM_INDEX,
  "fps_rate": $FPS,
  "grid_layout": "$GRID_LAYOUT",
  "total_frames_extracted": $EXTRACTED,
  "montage_grids": $GRIDS,
  "scene_changes": $SCENE_COUNT,
  "output_directory": "$OUTPUT_DIR"
}
METAEOF

echo ""
echo "=== Done ==="
echo "Frames:      ${OUTPUT_DIR}/frame_*.jpg"
echo "Grids:       ${OUTPUT_DIR}/grid_*.jpg"
echo "Key frames:  ${OUTPUT_DIR}/key_frames/"
echo "Scenes:      $SCENE_FILE"
echo "Meta:        ${OUTPUT_DIR}/metadata.json"
