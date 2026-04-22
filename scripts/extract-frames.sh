#!/usr/bin/env bash
# Video Frame Extraction Script
# Usage: extract-frames.sh <input_video> <output_dir> <fps_rate> [max_frames] [stream_index] [grid_layout]
# Example: extract-frames.sh video.mp4 /tmp/frames 2 0 1 4x4
# fps_rate examples: 2 (2/sec), 1 (1/sec), 0.1 (1/10sec), 0.05 (1/20sec)
# stream_index: video stream index (default: auto-detect, skipping thumbnails)
# grid_layout: tile layout for montage grids (default: 4x4)

set -euo pipefail

# Add ffmpeg path for Windows compatibility (put ffmpeg binaries in ~/bin/)
export PATH="$HOME/bin:$PATH"

INPUT="${1:?Usage: extract-frames.sh <input_video> <output_dir> <fps_rate> [max_frames] [stream_index] [grid_layout] [start_time] [end_time]}"
OUTPUT_DIR="${2:?Specify output directory}"
FPS="${3:?Specify fps rate (e.g., 2, 1, 0.1, 0.05)}"
MAX_FRAMES="${4:-0}"  # 0 = unlimited
STREAM_INDEX="${5:-auto}"  # auto = detect correct stream
GRID_LAYOUT="${6:-4x4}"  # tile layout for grids
START_TIME="${7:-}"  # e.g., "00:00:10" or "10" (seconds)
END_TIME="${8:-}"    # e.g., "00:00:30" or "30" (seconds)

# Validate input
if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: File not found: $INPUT" >&2
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
MAP_ARG="-map 0:${STREAM_INDEX}"

# Build time range arguments
TIME_ARGS=""
if [[ -n "$START_TIME" ]]; then
    TIME_ARGS="-ss $START_TIME"
fi
if [[ -n "$END_TIME" ]]; then
    TIME_ARGS="$TIME_ARGS -to $END_TIME"
fi

# Get video info from the correct stream
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" 2>/dev/null)
RESOLUTION=$(ffprobe -v error -select_streams v:${STREAM_INDEX} -show_entries stream=width,height -of csv=p=0 "$INPUT" 2>/dev/null || echo "unknown")
# Use python3 instead of bc for Windows compatibility
TOTAL_FRAMES=$(python3 -c "print(int($DURATION * $FPS))" 2>/dev/null)

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
FRAME_LIMIT=""
if [[ "$MAX_FRAMES" -gt 0 ]]; then
    FRAME_LIMIT="-frames:v $MAX_FRAMES"
    echo "Frame limit: $MAX_FRAMES"
fi

# Extract individual frames as JPG
# Note: $MAP_ARG, $TIME_ARGS, $FRAME_LIMIT intentionally unquoted for word splitting
ffmpeg -i "$INPUT" \
    $MAP_ARG \
    $TIME_ARGS \
    -vf "$FILTER" \
    -q:v 2 \
    $FRAME_LIMIT \
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

# Note: $MAP_ARG, $TIME_ARGS intentionally unquoted for word splitting
ffmpeg -i "$INPUT" \
    $MAP_ARG \
    $TIME_ARGS \
    -vf "$MONTAGE_FILTER" \
    -q:v 2 \
    "${OUTPUT_DIR}/grid_%03d.jpg" \
    -y -loglevel warning 2>&1

GRIDS=$(ls "${OUTPUT_DIR}"/grid_*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "Created: $GRIDS montage grids (${GRID_LAYOUT})"

# Detect scene changes (key moments)
echo ""
echo "=== Scene Change Detection ==="
SCENE_FILE="${OUTPUT_DIR}/scene_changes.txt"
# Note: $MAP_ARG, $TIME_ARGS intentionally unquoted for word splitting
ffmpeg -i "$INPUT" \
    $MAP_ARG \
    $TIME_ARGS \
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
            $MAP_ARG \
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
