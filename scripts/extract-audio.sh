#!/usr/bin/env bash
# Audio Extraction and Transcription Script
# Usage: extract-audio.sh <input_video> <output_dir> [whisper_model] [start_time] [end_time]
# Example: extract-audio.sh video.mp4 /tmp/audio medium
# whisper_model:  tiny|base|small|medium|large|turbo (openai-whisper backend; default: base)
# start/end_time: seconds, MM:SS or HH:MM:SS; "" to leave open
#
# Environment:
#   WHISPER_BACKEND    auto (default) | mlx | openai | none
#                      auto prefers mlx_whisper on Apple Silicon when it is installed,
#                      then the openai-whisper CLI, and skips transcription otherwise.
#   WHISPER_MLX_MODEL  model repo for the mlx backend
#                      (default: mlx-community/whisper-large-v3-turbo)
#   WHISPER_LANGUAGE   language code, e.g. "en" (default: auto-detect)
#
# Exit codes: 0 ok (including "no audio" and "no transcription tool"),
#             1 bad input, 3 audio extracted but transcription failed.
#
# Transcript timestamps written by Whisper (audio.json/srt/vtt) are relative to
# start_time. transcript.txt has absolute timestamps that match the frames.

set -euo pipefail

[[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && export PATH="$HOME/bin:$PATH"

USAGE="Usage: extract-audio.sh <input_video> <output_dir> [whisper_model] [start_time] [end_time]"
INPUT="${1:?$USAGE}"
OUTPUT_DIR="${2:?Specify output directory}"
MODEL="${3:-base}"
START_TIME="${4:-}"
END_TIME="${5:-}"
BACKEND="${WHISPER_BACKEND:-auto}"
MLX_MODEL="${WHISPER_MLX_MODEL:-mlx-community/whisper-large-v3-turbo}"
LANGUAGE="${WHISPER_LANGUAGE:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/vahelper.py"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$INPUT" ]] || fail "File not found: $INPUT"
[[ "$BACKEND" =~ ^(auto|mlx|openai|none)$ ]] || fail "WHISPER_BACKEND must be auto, mlx, openai or none, got: $BACKEND"
[[ "$MODEL" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid whisper model name: $MODEL"
[[ -z "$LANGUAGE" || "$LANGUAGE" =~ ^[A-Za-z-]+$ ]] || fail "invalid WHISPER_LANGUAGE: $LANGUAGE"

OFFSET=0
SEEK_ARGS=()
if [[ -n "$START_TIME" ]]; then
    OFFSET=$(python3 "$HELPER" seconds "$START_TIME")
    SEEK_ARGS+=(-ss "$OFFSET")
fi
if [[ -n "$END_TIME" ]]; then
    SEEK_ARGS+=(-to "$(python3 "$HELPER" seconds "$END_TIME")")
fi

# Absolute paths: a relative name like "12:30 talk.mp4" or "-clip.mp4" would
# otherwise be read by ffmpeg as a protocol or an option.
INPUT="$(cd "$(dirname -- "$INPUT")" && pwd)/$(basename -- "$INPUT")"
mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
AUDIO_FILE="${OUTPUT_DIR}/audio.wav"
SILENCE_FILE="${OUTPUT_DIR}/silence.txt"
VOLUME_FILE="${OUTPUT_DIR}/volume.txt"
TRANSCRIPT_FILE="${OUTPUT_DIR}/transcript.txt"
META_FILE="${OUTPUT_DIR}/audio_metadata.json"

# Remove output from a previous run so a stale transcript is never analysed.
rm -f "$AUDIO_FILE" "$SILENCE_FILE" "$VOLUME_FILE" "$TRANSCRIPT_FILE" "$META_FILE" \
      "${OUTPUT_DIR}"/audio.{txt,json,srt,vtt,tsv} "${OUTPUT_DIR}"/audio.wav.{txt,srt,vtt}

echo "=== Audio Extraction ==="
echo "Input: $INPUT"
echo "Time range: ${START_TIME:-start} - ${END_TIME:-end}"

AUDIO_STREAMS=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$INPUT") \
    || fail "ffprobe could not read $INPUT"
if [[ -z "$AUDIO_STREAMS" ]]; then
    echo "No audio stream found. Skipping audio extraction and transcription."
    python3 "$HELPER" json "$META_FILE" \
        "s:source=$(basename "$INPUT")" "b:has_audio=false" "b:transcribed=false" "s:backend=none"
    exit 0
fi

# 16kHz mono WAV is what Whisper models expect.
echo ""
echo "Extracting audio to WAV (16kHz mono)..."
ffmpeg -nostdin -hide_banner -loglevel error -y \
    ${SEEK_ARGS[@]+"${SEEK_ARGS[@]}"} -i "$INPUT" \
    -map 0:a:0 -vn -acodec pcm_s16le -ar 16000 -ac 1 "$AUDIO_FILE"
echo "Audio extracted: $AUDIO_FILE"

echo ""
echo "=== Silence Detection ==="
ffmpeg -nostdin -hide_banner -i "$AUDIO_FILE" \
    -af "silencedetect=noise=-30dB:d=0.5" \
    -f null - 2>&1 | grep -E "silence_(start|end)" > "$SILENCE_FILE" || true
if [[ -s "$SILENCE_FILE" ]]; then
    echo "Silence segments: $(grep -c 'silence_start' "$SILENCE_FILE" || true) (see ${SILENCE_FILE}; times relative to ${OFFSET}s)"
else
    echo "No significant silence detected"
fi

echo ""
echo "=== Volume Analysis ==="
ffmpeg -nostdin -hide_banner -i "$AUDIO_FILE" \
    -af "volumedetect" \
    -f null - 2>&1 | grep -E "(mean_volume|max_volume)" > "$VOLUME_FILE" || true
[[ -s "$VOLUME_FILE" ]] && cat "$VOLUME_FILE"

# --- Pick a transcription backend -------------------------------------------
is_apple_silicon() { [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; }

WHISPER_CMD=()
case "$BACKEND" in
    auto)
        if is_apple_silicon && command -v mlx_whisper &>/dev/null; then
            BACKEND="mlx"; WHISPER_CMD=(mlx_whisper)
        elif command -v whisper &>/dev/null; then
            BACKEND="openai"; WHISPER_CMD=(whisper)
        else
            BACKEND="none"
            echo ""
            echo "WARNING: no transcription tool found (looked for mlx_whisper and whisper)."
            echo "Install one: 'uv tool install mlx-whisper' (Apple Silicon) or 'pip install openai-whisper'."
        fi
        ;;
    mlx)
        if command -v mlx_whisper &>/dev/null; then
            WHISPER_CMD=(mlx_whisper)
        elif command -v uvx &>/dev/null; then
            WHISPER_CMD=(uvx --from mlx-whisper mlx_whisper)
        else
            fail "WHISPER_BACKEND=mlx needs mlx_whisper (uv tool install mlx-whisper) or uvx on PATH"
        fi
        ;;
    openai)
        command -v whisper &>/dev/null || fail "WHISPER_BACKEND=openai needs the whisper CLI (pip install openai-whisper)"
        WHISPER_CMD=(whisper)
        ;;
    none) ;;
esac

LANG_ARGS=()
[[ -n "$LANGUAGE" ]] && LANG_ARGS=(--language "$LANGUAGE")

TRANSCRIBED="false"
TRANSCRIBE_ERROR=""
USED_MODEL=""
echo ""
case "$BACKEND" in
    mlx)
        USED_MODEL="$MLX_MODEL"
        echo "=== Transcription (mlx-whisper, $USED_MODEL) ==="
        "${WHISPER_CMD[@]}" "$AUDIO_FILE" \
            --model "$MLX_MODEL" \
            --output-dir "$OUTPUT_DIR" --output-name audio --output-format all \
            --verbose False ${LANG_ARGS[@]+"${LANG_ARGS[@]}"} 2>&1 || TRANSCRIBE_ERROR="mlx_whisper exited with an error"
        ;;
    openai)
        USED_MODEL="$MODEL"
        echo "=== Transcription (openai-whisper, $USED_MODEL) ==="
        # Releases before 2023 have no --output_format and write only txt/vtt/srt.
        FORMAT_ARGS=()
        WHISPER_HELP=$("${WHISPER_CMD[@]}" --help 2>&1 || true)
        if [[ "$WHISPER_HELP" == *"--output_format"* ]]; then
            FORMAT_ARGS=(--output_format all)
        else
            echo "NOTE: this openai-whisper is outdated (no JSON output, no turbo/large-v3 models)."
            echo "      Upgrade with: pip install -U openai-whisper"
        fi
        "${WHISPER_CMD[@]}" "$AUDIO_FILE" \
            --model "$MODEL" \
            --output_dir "$OUTPUT_DIR" ${FORMAT_ARGS[@]+"${FORMAT_ARGS[@]}"} \
            --verbose False ${LANG_ARGS[@]+"${LANG_ARGS[@]}"} 2>&1 || TRANSCRIBE_ERROR="whisper exited with an error"
        ;;
    none)
        echo "=== Transcription skipped ==="
        ;;
esac

SEGMENTS=0
DETECTED_LANGUAGE=""
if [[ "$BACKEND" != "none" && -z "$TRANSCRIBE_ERROR" ]]; then
    # Prefer JSON; old whisper releases only leave subtitle files, named after
    # the full input filename (audio.wav.srt).
    TRANSCRIPT_SOURCE=""
    for candidate in audio.json audio.srt audio.wav.srt audio.vtt audio.wav.vtt; do
        if [[ -s "${OUTPUT_DIR}/${candidate}" ]]; then
            TRANSCRIPT_SOURCE="${OUTPUT_DIR}/${candidate}"
            break
        fi
    done
    if [[ -n "$TRANSCRIPT_SOURCE" ]]; then
        RESULT=$(python3 "$HELPER" transcript "$TRANSCRIPT_SOURCE" "$OFFSET" "$TRANSCRIPT_FILE")
        IFS=$'\t' read -r SEGMENTS DETECTED_LANGUAGE <<< "$RESULT"
        TRANSCRIBED="true"
        echo "Transcription complete: $SEGMENTS segments, language: $DETECTED_LANGUAGE"
    else
        TRANSCRIBE_ERROR="transcription finished without producing a transcript file"
    fi
fi

python3 "$HELPER" json "$META_FILE" \
    "s:source=$(basename "$INPUT")" \
    "b:has_audio=true" \
    "s:audio_file=$AUDIO_FILE" \
    "b:transcribed=$TRANSCRIBED" \
    "s:backend=$BACKEND" \
    "s:whisper_model=$USED_MODEL" \
    "s:language=$DETECTED_LANGUAGE" \
    "n:segments=$SEGMENTS" \
    "n:time_offset_seconds=$OFFSET" \
    "s:transcription_error=$TRANSCRIBE_ERROR" \
    "s:transcript_file=$TRANSCRIPT_FILE" \
    "s:silence_file=$SILENCE_FILE" \
    "s:volume_file=$VOLUME_FILE" \
    "n:sample_rate=16000" \
    "n:channels=1"

echo ""
echo "=== Done ==="
echo "Audio:      $AUDIO_FILE"
[[ "$TRANSCRIBED" == "true" ]] && echo "Transcript: $TRANSCRIPT_FILE (absolute timestamps)"
echo "Silence:    $SILENCE_FILE"
echo "Volume:     $VOLUME_FILE"
echo "Meta:       $META_FILE"

if [[ -n "$TRANSCRIBE_ERROR" ]]; then
    # Audio, silence and volume data are still usable; the caller must know
    # there is no transcript rather than assume the video has no speech.
    echo "ERROR: transcription failed: $TRANSCRIBE_ERROR (backend: $BACKEND)" >&2
    exit 3
fi
exit 0
