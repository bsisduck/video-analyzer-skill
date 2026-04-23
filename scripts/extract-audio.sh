#!/usr/bin/env bash
# Audio Extraction and Transcription Script
# Usage: extract-audio.sh <input_video> <output_dir> [whisper_model]
# Example: extract-audio.sh video.mp4 /tmp/audio medium

set -euo pipefail

# Add ffmpeg path for Windows compatibility (put ffmpeg binaries in ~/bin/)
export PATH="$HOME/bin:$PATH"

INPUT="${1:?Usage: extract-audio.sh <input_video> <output_dir> [whisper_model]}"
OUTPUT_DIR="${2:?Specify output directory}"
MODEL="${3:-base}"  # tiny|base|small|medium|large

# Validate input
if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: File not found: $INPUT" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=== Audio Extraction ==="
echo "Input: $INPUT"
echo "Model: $MODEL"

# Get audio stream info
AUDIO_INFO=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels,bit_rate -of json "$INPUT" 2>/dev/null)
echo "Audio info: $AUDIO_INFO"

# Extract audio as WAV (16kHz mono - optimal for Whisper)
AUDIO_FILE="${OUTPUT_DIR}/audio.wav"
echo ""
echo "Extracting audio to WAV (16kHz mono)..."
ffmpeg -i "$INPUT" \
    -vn \
    -acodec pcm_s16le \
    -ar 16000 \
    -ac 1 \
    "$AUDIO_FILE" \
    -y -loglevel warning 2>&1

echo "Audio extracted: $AUDIO_FILE"

# Detect silence segments
echo ""
echo "=== Silence Detection ==="
SILENCE_FILE="${OUTPUT_DIR}/silence.txt"
ffmpeg -i "$AUDIO_FILE" \
    -af "silencedetect=noise=-30dB:d=0.5" \
    -f null - 2>&1 | grep -E "silence_(start|end)" > "$SILENCE_FILE" || true

if [[ -s "$SILENCE_FILE" ]]; then
    echo "Silence segments detected (see ${SILENCE_FILE}):"
    cat "$SILENCE_FILE"
else
    echo "No significant silence detected"
fi

# Audio volume analysis
echo ""
echo "=== Volume Analysis ==="
VOLUME_FILE="${OUTPUT_DIR}/volume.txt"
ffmpeg -i "$AUDIO_FILE" \
    -af "volumedetect" \
    -f null - 2>&1 | grep -E "(mean_volume|max_volume|histogram)" > "$VOLUME_FILE" || true

if [[ -s "$VOLUME_FILE" ]]; then
    cat "$VOLUME_FILE"
fi

# Transcription with Whisper
echo ""
echo "=== Transcription (Whisper $MODEL) ==="

# Check if whisper is available
if command -v whisper &>/dev/null; then
    whisper "$AUDIO_FILE" \
        --model "$MODEL" \
        --output_dir "$OUTPUT_DIR" \
        --output_format all \
        --verbose False \
        2>&1

    echo "Transcription complete. Output files:"
    ls -la "${OUTPUT_DIR}"/audio.{txt,json,srt,vtt,tsv} 2>/dev/null || true
else
    echo "WARNING: whisper CLI not found."
    echo "Install with: pip install openai-whisper"
    echo "Skipping transcription."
fi

# Write audio metadata
cat > "${OUTPUT_DIR}/audio_metadata.json" <<EOF
{
  "source": "$(basename "$INPUT")",
  "audio_file": "$AUDIO_FILE",
  "whisper_model": "$MODEL",
  "silence_file": "$SILENCE_FILE",
  "volume_file": "$VOLUME_FILE",
  "sample_rate": 16000,
  "channels": 1
}
EOF

echo ""
echo "=== Done ==="
echo "Audio:         $AUDIO_FILE"
echo "Transcription: ${OUTPUT_DIR}/audio.json"
echo "Silence:       $SILENCE_FILE"
echo "Volume:        $VOLUME_FILE"
