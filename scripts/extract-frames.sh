#!/usr/bin/env bash
# Video Frame Extraction Script
# Usage: extract-frames.sh <input_video> <output_dir> <fps_rate> [max_frames] [stream_index] [grid_layout] [start_time] [end_time] [scene_threshold]
# Example: extract-frames.sh video.mp4 /tmp/frames 2 0 auto 4x4
# fps_rate:        2 (2/sec), 1 (1/sec), 0.1 (1/10sec), 0.05 (1/20sec)
# max_frames:      stop sampling after N frames, 0 = unlimited (default: 0)
# stream_index:    absolute video stream index, or "auto" to skip thumbnails (default: auto)
# grid_layout:     COLSxROWS tile layout for montage grids (default: 4x4)
# start/end_time:  seconds, MM:SS or HH:MM:SS; "" to leave open
# scene_threshold: scene-change sensitivity 0-1 (default: 0.3)
# Set VA_KEEP_FRAMES=1 to also write the individual frame_*.jpg files.
#
# Every timestamp this script burns in or writes is video time as a player
# shows it (0 = first frame), also when a time range is used.

set -euo pipefail

[[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && export PATH="$HOME/bin:$PATH"

USAGE="Usage: extract-frames.sh <input_video> <output_dir> <fps_rate> [max_frames] [stream_index] [grid_layout] [start_time] [end_time] [scene_threshold]"
INPUT="${1:?$USAGE}"
OUTPUT_DIR="${2:?Specify output directory}"
FPS="${3:?Specify fps rate (e.g., 2, 1, 0.1, 0.05)}"
MAX_FRAMES="${4:-0}"
STREAM_INDEX="${5:-auto}"
GRID_LAYOUT="${6:-4x4}"
START_TIME="${7:-}"
END_TIME="${8:-}"
SCENE_THRESHOLD="${9:-0.3}"
KEEP_FRAMES="${VA_KEEP_FRAMES:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/vahelper.py"
GRID_TARGET_WIDTH=1920   # widest montage; larger images get downscaled before analysis
KEY_FRAME_EDGE=1280      # longest edge of a key frame
MAX_KEY_FRAMES=20

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$INPUT" ]] || fail "File not found: $INPUT"

# Every value below is interpolated into an ffmpeg filter graph, so reject
# anything that is not the expected shape.
NUMBER_RE='^[0-9]+([.][0-9]+)?$'
[[ "$FPS" =~ $NUMBER_RE ]] || fail "fps_rate must be a positive number, got: $FPS"
[[ "$FPS" =~ ^0+([.]0+)?$ ]] && fail "fps_rate must be greater than 0"
[[ "$MAX_FRAMES" =~ ^[0-9]+$ ]] || fail "max_frames must be a whole number, got: $MAX_FRAMES"
[[ "$STREAM_INDEX" == "auto" || "$STREAM_INDEX" =~ ^[0-9]+$ ]] || fail "stream_index must be a number or 'auto', got: $STREAM_INDEX"
[[ "$GRID_LAYOUT" =~ ^[1-9][0-9]?x[1-9][0-9]?$ ]] || fail "grid_layout must look like 4x4, got: $GRID_LAYOUT"
[[ "$SCENE_THRESHOLD" =~ $NUMBER_RE ]] || fail "scene_threshold must be a number between 0 and 1, got: $SCENE_THRESHOLD"

# Absolute paths: ffmpeg runs from inside the output directory (so filter
# graphs can use plain relative filenames), and a relative name such as
# "12:30 talk.mp4" or "-clip.mp4" would be read as a protocol or an option.
INPUT="$(cd "$(dirname -- "$INPUT")" && pwd)/$(basename -- "$INPUT")"
mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"

SEEK_ARGS=()
START_SEC=""
if [[ -n "$START_TIME" ]]; then
    START_SEC=$(python3 "$HELPER" seconds "$START_TIME")
    SEEK_ARGS+=(-ss "$START_SEC")
fi
if [[ -n "$END_TIME" ]]; then
    END_SEC=$(python3 "$HELPER" seconds "$END_TIME")
    SEEK_ARGS+=(-to "$END_SEC")
fi

# Resolves "auto", and reports the display size, the stream time base and the
# container start offset (non-zero for MPEG-TS and some MOV files).
STREAM_INFO=$(python3 "$HELPER" streaminfo "$INPUT" "$STREAM_INDEX" "$START_SEC")
IFS=$'\t' read -r STREAM_INDEX DISPLAY_W DISPLAY_H TIME_BASE START_OFFSET DURATION <<< "$STREAM_INFO"
RESOLUTION="${DISPLAY_W}x${DISPLAY_H}"

# Remove output from a previous run so stale grids are never analysed.
rm -rf "${OUTPUT_DIR}/key_frames"
rm -f "${OUTPUT_DIR}"/grid_*.jpg "${OUTPUT_DIR}"/frame_*.jpg \
      "${OUTPUT_DIR}/scene_changes.txt" "${OUTPUT_DIR}/metadata.json" \
      "${OUTPUT_DIR}/frames_raw.txt" "${OUTPUT_DIR}/scenes_raw.txt"

GRID_COLS="${GRID_LAYOUT%x*}"
CELL_WIDTH=$(( GRID_TARGET_WIDTH / GRID_COLS ))
CELL_FONT=$(( CELL_WIDTH / 16 ))

echo "=== Video Frame Extraction ==="
echo "Input: $INPUT"
echo "Duration: ${DURATION}s"
echo "Resolution: $RESOLUTION"
echo "Video stream: $STREAM_INDEX"
echo "FPS rate: $FPS"
echo "Time range: ${START_TIME:-start} - ${END_TIME:-end}"
echo "Grid layout: $GRID_LAYOUT (${CELL_WIDTH}px cells)"
echo "Scene threshold: $SCENE_THRESHOLD"
echo "Output: $OUTPUT_DIR"
echo ""

# Sample the first frame of each 1/fps slot and keep its real timestamp.
# (The fps filter would instead relabel the nearest frame, so a frame stamped
# 00:00:10 at 0.1 fps would really show 00:00:15.) The first frame is always
# kept, which also guarantees at least one frame for very short ranges.
SLOT="floor((t-(${START_OFFSET}))*${FPS})"
PREV_SLOT="floor((prev_selected_t-(${START_OFFSET}))*${FPS})"
SAMPLE="select='isnan(prev_selected_t)+gt(${SLOT},${PREV_SLOT})'"
if [[ "$MAX_FRAMES" -gt 0 ]]; then
    SAMPLE="${SAMPLE},trim=end_frame=${MAX_FRAMES}"
    echo "Frame limit: $MAX_FRAMES"
fi

# drawtext's pts function takes an offset; subtracting the container start
# offset makes the burned-in time start at 0 like a player does.
stamp() {  # stamp <fontsize>
    echo "drawtext=text='%{pts\\:hms\\:-${START_OFFSET}}':x=6:y=6:fontsize=${1}:fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=5"
}

# One decode feeds every output: sampled frames -> montage grids, the full
# stream -> scene detection, and (optionally) individual frames.
BRANCHES=2
[[ "$KEEP_FRAMES" == "1" ]] && BRANCHES=3
GRAPH="[0:${STREAM_INDEX}]split=${BRANCHES}[grid_in][scene_in]"
[[ "$KEEP_FRAMES" == "1" ]] && GRAPH="${GRAPH}[frame_in]"
# metadata=print only logs frames that carry metadata, so the pass-through
# select (which tags each frame with a scene score) makes it log every frame.
GRAPH="${GRAPH};[grid_in]${SAMPLE},select='gte(scene,0)',metadata=print:file=frames_raw.txt,scale='min(${CELL_WIDTH},iw)':-2,$(stamp "$CELL_FONT"),tile=${GRID_LAYOUT}[grid]"
# Every frame is scored and passed on to the null output; only frames whose
# score beats the threshold are logged. (Dropping the others with select
# would leave the output empty, and ffmpeg fails, when a video has no cuts.)
GRAPH="${GRAPH};[scene_in]select='gte(scene,0)',metadata=print:key=lavfi.scene_score:value=${SCENE_THRESHOLD}:function=greater:file=scenes_raw.txt[scene]"

# Sampled frames are irregularly spaced; without vfr ffmpeg would duplicate or
# drop images to fake a constant rate. -fps_mode replaced -vsync in ffmpeg 5.1.
FFMPEG_HELP=$(ffmpeg -hide_banner -h long 2>&1 || true)
if [[ "$FFMPEG_HELP" == *"-fps_mode"* ]]; then
    SYNC_ARGS=(-fps_mode vfr)
else
    SYNC_ARGS=(-vsync vfr)
fi

OUTPUTS=(-map "[grid]" "${SYNC_ARGS[@]}" -q:v 3 "grid_%03d.jpg" -map "[scene]" -f null -)
if [[ "$KEEP_FRAMES" == "1" ]]; then
    GRAPH="${GRAPH};[frame_in]${SAMPLE},scale='min(1280,iw)':-2,$(stamp 28)[frame]"
    OUTPUTS+=(-map "[frame]" "${SYNC_ARGS[@]}" -q:v 2 "frame_%05d.jpg")
fi

# -ss/-to before -i seeks instead of decoding from the start; -copyts keeps
# the original timestamps so times stay absolute within a range.
(
    cd "$OUTPUT_DIR"
    ffmpeg -nostdin -hide_banner -loglevel error -y \
        ${SEEK_ARGS[@]+"${SEEK_ARGS[@]}"} -copyts -i "$INPUT" \
        -filter_complex "$GRAPH" \
        "${OUTPUTS[@]}"
) || fail "ffmpeg could not extract frames from $INPUT"

# Scene changes: full list on disk, evenly spread picks become key frames.
SCENE_FILE="${OUTPUT_DIR}/scene_changes.txt"
PICKS=$(python3 "$HELPER" scenes "${OUTPUT_DIR}/scenes_raw.txt" "$SCENE_FILE" "$MAX_KEY_FRAMES" "$TIME_BASE" "$START_OFFSET")

if [[ -n "$PICKS" ]]; then
    mkdir -p "${OUTPUT_DIR}/key_frames"
    KEY_IDX=0
    KEY_SCALE="scale=w='if(gte(iw,ih),min(${KEY_FRAME_EDGE},iw),-2)':h='if(gte(iw,ih),-2,min(${KEY_FRAME_EDGE},ih))'"
    while IFS=$'\t' read -r TIMESTAMP LABEL; do
        [[ -n "$TIMESTAMP" ]] || continue
        KEY_IDX=$((KEY_IDX + 1))
        TS_SAFE="${TIMESTAMP//./_}"
        OUTFILE="${OUTPUT_DIR}/key_frames/scene_$(printf '%02d' "$KEY_IDX")_${TS_SAFE}s.jpg"
        KEY_FILTER="${KEY_SCALE},drawtext=text='${LABEL//:/\\:}':x=10:y=10:fontsize=32:fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=6"
        # Fast path: seek, then decode one frame. An input -ss is relative to
        # the container start, like TIMESTAMP.
        # -update 1: the decimal point in the name is not an image sequence pattern.
        ffmpeg -nostdin -hide_banner -loglevel fatal -y \
            -ss "$TIMESTAMP" -i "$INPUT" \
            -map "0:${STREAM_INDEX}" -frames:v 1 -vf "$KEY_FILTER" \
            -q:v 2 -update 1 "$OUTFILE" || true
        if [[ ! -s "$OUTFILE" ]]; then
            # Seeking can land where the decoder has no keyframe to start from
            # (open-GOP MPEG-TS). Decode from the beginning instead: slow, exact.
            ffmpeg -nostdin -hide_banner -loglevel fatal -y \
                -i "$INPUT" -ss "$TIMESTAMP" \
                -map "0:${STREAM_INDEX}" -frames:v 1 -vf "$KEY_FILTER" \
                -q:v 2 -update 1 "$OUTFILE" || true
        fi
        [[ -s "$OUTFILE" ]] || echo "WARNING: could not extract key frame at ${TIMESTAMP}s" >&2
    done <<< "$PICKS"
fi

SUMMARY=$(python3 "$HELPER" frames-meta \
    --out-dir "$OUTPUT_DIR" --source "$INPUT" --duration "$DURATION" \
    --resolution "$RESOLUTION" --stream "$STREAM_INDEX" --fps "$FPS" \
    --grid "$GRID_LAYOUT" --cell-width "$CELL_WIDTH" --threshold "$SCENE_THRESHOLD" \
    --frames-raw "${OUTPUT_DIR}/frames_raw.txt" --scene-file "$SCENE_FILE" \
    --start "$START_TIME" --end "$END_TIME" \
    --time-base "$TIME_BASE" "--offset=${START_OFFSET}")
IFS=$'\t' read -r EXTRACTED GRIDS SCENE_COUNT KEY_EXTRACTED <<< "$SUMMARY"
rm -f "${OUTPUT_DIR}/frames_raw.txt" "${OUTPUT_DIR}/scenes_raw.txt"

echo "Sampled: $EXTRACTED frames"
echo "Created: $GRIDS montage grids (${GRID_LAYOUT})"
echo "Detected: $SCENE_COUNT scene changes"
echo "Extracted: $KEY_EXTRACTED key frames at scene changes"

if [[ "$GRIDS" -eq 0 ]]; then
    fail "No frames were extracted. Check the time range and stream index."
fi

echo ""
echo "=== Done ==="
echo "Grids:       ${OUTPUT_DIR}/grid_*.jpg"
echo "Key frames:  ${OUTPUT_DIR}/key_frames/"
echo "Scenes:      $SCENE_FILE"
echo "Meta:        ${OUTPUT_DIR}/metadata.json"
[[ "$KEEP_FRAMES" == "1" ]] && echo "Frames:      ${OUTPUT_DIR}/frame_*.jpg"
exit 0
