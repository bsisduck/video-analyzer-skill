#!/usr/bin/env bash
# Test suite for the video-analyzer scripts.
# Usage: bash tests/run-tests.sh
#
# Builds small synthetic videos with ffmpeg, so it needs no sample files and no
# network. Requires ffmpeg, ffprobe and python3. shellcheck is used if present.
# Set RUN_WHISPER_TESTS=1 to also run a real transcription (macOS `say` for the
# speech sample plus an installed whisper or mlx_whisper CLI).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
# A directory with a space and an apostrophe, to prove paths are quoted properly.
TMP_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/va-tests.XXXXXX")"
WORK="$TMP_PARENT/work dir's"
mkdir -p "$WORK"
trap 'rm -rf "$TMP_PARENT"' EXIT

PASS=0
FAIL=0
FAILED=()

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$1"); echo "  FAIL $1${2:+ — $2}"; }
section() { echo ""; echo "== $1"; }

# check <name> <command...>: passes when the command succeeds
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
# refute <name> <command...>: passes when the command fails
refute() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$name" "expected failure"; else ok "$name"; fi; }
# eq <name> <actual> <expected>
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got '$2', expected '$3'"; fi; }

# The eval() below only ever sees expressions written in this file (never
# data from a video or from user input), so it is safe here.
# j <json-file> <python expression over d>: print the value
j() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
# jt <json-file> <python expression over d>: succeed when the expression is truthy
jt() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"; }

image_size() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1"; }
count() { find "$1" -maxdepth 1 -name "$2" 2>/dev/null | wc -l | tr -d ' '; }
gen() { ffmpeg -nostdin -hide_banner -loglevel error -y "$@"; }
# is_blue <image>: succeeds when the lower-right quarter (clear of the timestamp) is blue
is_blue() {
    ffmpeg -nostdin -hide_banner -loglevel error -i "$1" \
        -vf "crop=iw/2:ih/2:iw/2:ih/2,scale=1:1" -frames:v 1 -f rawvideo -pix_fmt rgb24 - \
        | python3 -c 'import sys; r, g, b = sys.stdin.buffer.read(3); sys.exit(0 if b > 150 and r < 80 and g < 80 else 1)'
}

for tool in ffmpeg ffprobe python3; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 2; }
done

# ---------------------------------------------------------------- fixtures --
section "Building fixtures"
cd "$WORK" || exit 2

# 12s landscape clip, three visually distinct 4s scenes (cuts at 4s and 8s), with audio
gen -f lavfi -i "testsrc=d=4:s=640x360:r=25" -f lavfi -i "smptebars=d=4:s=640x360:r=25" \
    -f lavfi -i "color=c=blue:d=4:s=640x360:r=25" -f lavfi -i "sine=f=440:d=12" \
    -filter_complex "[0:v][1:v][2:v]concat=n=3:v=1[v]" -map "[v]" -map 3:a \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "scenes clip's.mp4"
gen -f lavfi -i "testsrc2=d=6:s=360x640:r=25" -c:v libx264 -pix_fmt yuv420p portrait.mp4
gen -f lavfi -i "color=c=gray:d=6:s=640x360:r=25" -c:v libx264 -pix_fmt yuv420p static.mp4
gen -f lavfi -i "color=c=red:s=320x320:d=1" -frames:v 1 cover.jpg
# audio first, real video second, cover art last: the video is not stream 0
gen -i "scenes clip's.mp4" -i cover.jpg -map 0:a -map 0:v -map 1:v -c copy \
    -disposition:v:1 attached_pic thumb.mp4
printf '1\n00:00:00,500 --> 00:00:02,000\nHello from the subtitle track\n\n2\n00:00:02,500 --> 00:00:03,500\nSecond cue\n' > cues.srt
gen -i "scenes clip's.mp4" -i cues.srt -map 0 -map 1 -c copy -c:s mov_text subs.mp4
cp "scenes clip's.mp4" 'has "quotes".mp4'
cp "scenes clip's.mp4" sidecar.mp4 && cp cues.srt sidecar.en.srt
# names ffmpeg would misread as a protocol or an option when passed relative
cp "scenes clip's.mp4" "12:30 talk.mp4"
cp -- "scenes clip's.mp4" "-dash.mp4"
# MPEG-TS starts its timestamps above zero
gen -i "scenes clip's.mp4" -c copy offset.ts
HAVE_ROTATED=0
if gen -display_rotation 90 -i "scenes clip's.mp4" -c copy rotated.mp4 2>/dev/null; then HAVE_ROTATED=1; fi

CLIP="$WORK/scenes clip's.mp4"
check "fixtures were created" test -s "$CLIP" -a -s portrait.mp4 -a -s thumb.mp4 -a -s subs.mp4

# ------------------------------------------------------------------- lint --
section "Static checks"
for script in "$SCRIPTS"/*.sh "$ROOT/tests/run-tests.sh"; do
    check "bash -n $(basename "$script")" bash -n "$script"
done
if command -v shellcheck >/dev/null; then
    check "shellcheck" shellcheck "$SCRIPTS"/*.sh "$ROOT/tests/run-tests.sh"
else
    echo "  skip shellcheck (not installed)"
fi
check "vahelper unit tests" python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py'

# ------------------------------------------------------------- video-info --
section "video-info.sh"
bash "$SCRIPTS/video-info.sh" "$CLIP" > info.json 2>/dev/null
check "emits valid JSON" jt info.json 'isinstance(d, dict)'
eq "short tier" "$(j info.json 'd["tier"]')" "short"
eq "2 fps for short tier" "$(j info.json 'd["fps_rate"]')" "2.0"
eq "landscape grid" "$(j info.json 'd["grid_layout"]')" "4x4"
eq "audio detected" "$(j info.json 'd["has_audio"]')" "True"
eq "no subtitles" "$(j info.json 'd["has_subtitles"]')" "False"
check "work dir has no spaces or quotes" jt info.json '" " not in d["work_dir"] and "\x27" not in d["work_dir"]'

bash "$SCRIPTS/video-info.sh" 'has "quotes".mp4' > quotes.json 2>/dev/null
eq "valid JSON for a filename with quotes" "$(j quotes.json 'd["file"]')" 'has "quotes".mp4'

bash "$SCRIPTS/video-info.sh" portrait.mp4 > portrait.json
eq "portrait orientation" "$(j portrait.json 'd["orientation"]')" "portrait"
eq "portrait grid" "$(j portrait.json 'd["grid_layout"]')" "5x2"
eq "no audio detected" "$(j portrait.json 'd["has_audio"]')" "False"

bash "$SCRIPTS/video-info.sh" thumb.mp4 > thumb.json
eq "absolute index of real video stream" "$(j thumb.json 'd["video_stream_index"]')" "1"
eq "thumbnail size is not reported" "$(j thumb.json 'd["width"]')" "640"

if [[ "$HAVE_ROTATED" == "1" ]]; then
    bash "$SCRIPTS/video-info.sh" rotated.mp4 > rotated.json
    eq "rotation metadata makes it portrait" "$(j rotated.json 'd["orientation"]')" "portrait"
else
    echo "  skip rotation (this ffmpeg lacks -display_rotation)"
fi

bash "$SCRIPTS/video-info.sh" subs.mp4 > subs.json
eq "embedded subtitles detected" "$(j subs.json 'd["has_subtitles"]')" "True"
eq "subtitle codec reported" "$(j subs.json 'd["subtitle_streams"][0]["codec"]')" "mov_text"
bash "$SCRIPTS/video-info.sh" sidecar.mp4 > sidecar.json
check "sidecar subtitle file detected" jt sidecar.json 'len(d["sidecar_subtitles"]) == 1 and d["has_subtitles"]'

bash "$SCRIPTS/video-info.sh" "$CLIP" "" 4 8 > range.json
eq "time range sets effective duration" "$(j range.json 'd["effective_duration"]')" "4.0"
bash "$SCRIPTS/video-info.sh" "$CLIP" "" 0:04 0:08 > range2.json
eq "MM:SS time range" "$(j range2.json 'd["effective_duration"]')" "4.0"

bash "$SCRIPTS/video-info.sh" "$CLIP" 100 > capped.json
eq "custom tier" "$(j capped.json 'd["tier"]')" "custom"
eq "frame budget enforced" "$(j capped.json 'd["expected_frames"]')" "200"
check "rate lowered to cover the whole clip" jt capped.json 'd["fps_capped"] and abs(d["fps_rate"] * d["effective_duration"] - 200) < 1'
eq "requested rate kept for reporting" "$(j capped.json 'd["requested_fps"]')" "100.0"

refute "rejects an inverted time range" bash "$SCRIPTS/video-info.sh" "$CLIP" "" 8 4
refute "rejects a missing file" bash "$SCRIPTS/video-info.sh" "$WORK/absent.mp4"
refute "rejects a non-numeric fps" bash "$SCRIPTS/video-info.sh" "$CLIP" fast
refute "rejects a nan fps" bash "$SCRIPTS/video-info.sh" "$CLIP" nan
bash "$SCRIPTS/video-info.sh" "12:30 talk.mp4" > colon.json 2>/dev/null
eq "relative name containing a colon" "$(j colon.json 'd["has_audio"]')" "True"
bash "$SCRIPTS/video-info.sh" "-dash.mp4" > dash.json 2>/dev/null
eq "relative name starting with a dash" "$(j dash.json 'd["file"]')" "-dash.mp4"
refute "rejects a file without video" bash "$SCRIPTS/video-info.sh" cues.srt

# --------------------------------------------------------- extract-frames --
section "extract-frames.sh"
OUT="$WORK/frames out"
check "full run succeeds" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 2 0 auto 4x4
M="$OUT/metadata.json"
eq "24 frames sampled (2fps x 12s)" "$(j "$M" 'd["total_frames_extracted"]')" "24"
eq "2 grids" "$(j "$M" 'd["montage_grids"]')" "2"
eq "grid files match metadata" "$(count "$OUT" 'grid_*.jpg')" "2"
check "scene changes near 4s and 8s" jt "$M" 'len(d["scene_change_times"]) == 2 and abs(d["scene_change_times"][0] - 4) < 0.2 and abs(d["scene_change_times"][1] - 8) < 0.2'
eq "one key frame per scene change" "$(count "$OUT/key_frames" 'scene_*.jpg')" "2"
check "grid index covers the clip" jt "$M" 'd["grids"][0]["start_seconds"] == 0 and d["grids"][-1]["end_seconds"] > 11'
check "no individual frames by default" test "$(count "$OUT" 'frame_*.jpg')" = "0"
check "temporary logs removed" test ! -e "$OUT/frames_raw.txt" -a ! -e "$OUT/scenes_raw.txt"
GRID_W="$(image_size "$OUT/grid_001.jpg" | cut -dx -f1)"
GRID_H="$(image_size "$OUT/grid_001.jpg" | cut -dx -f2)"
check "grid fits within 2000px" test "$GRID_W" -le 2000 -a "$GRID_H" -le 2000

check "time range run succeeds" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 2 0 auto 4x4 4 8
eq "8 frames in a 4s range" "$(j "$M" 'd["total_frames_extracted"]')" "8"
check "timestamps stay absolute" jt "$M" 'd["grids"][0]["start_seconds"] >= 4 and d["grids"][-1]["end_seconds"] < 8'
eq "previous run's second grid was removed" "$(count "$OUT" 'grid_*.jpg')" "1"
eq "no cut inside the 4-8s range" "$(j "$M" 'd["scene_changes"]')" "0"
check "previous run's key frames were removed" test ! -e "$OUT/key_frames"

check "start-only range succeeds" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 2 0 auto 4x4 8 ""
check "start-only range begins at the start time" jt "$M" 'd["grids"][0]["start_seconds"] >= 8 and d["grids"][-1]["end_seconds"] > 11'
check "end-only range succeeds" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 2 0 auto 4x4 "" 0:04
check "end-only range stops at the end time" jt "$M" 'd["grids"][0]["start_seconds"] == 0 and d["grids"][-1]["end_seconds"] < 4'

# A burned-in time must be the time of the frame shown. Sampling every 3.5s
# takes frames at 0, 3.5, 7 and 10.5s; the clip turns blue at 8s.
VA_KEEP_FRAMES=1 bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 0.2857 >/dev/null 2>&1
eq "sparse sampling takes one frame per slot" "$(j "$M" 'd["total_frames_extracted"]')" "4"
check "sample times are real frame times" jt "$M" 'abs(d["grids"][0]["end_seconds"] - 10.5) < 0.1'
refute "frame stamped 7.0s is from before the 8s cut" is_blue "$OUT/frame_00003.jpg"
check "frame stamped 10.5s is from after the 8s cut" is_blue "$OUT/frame_00004.jpg"

check "rate lower than one frame per clip still yields a frame" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 0.03
eq "exactly one frame" "$(j "$M" 'd["total_frames_extracted"]')" "1"
check "range shorter than one frame interval succeeds" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 2 0 auto 4x4 11.9 12
check "tiny range yields a grid" test "$(count "$OUT" 'grid_*.jpg')" = "1"

check "container with a start offset succeeds" bash "$SCRIPTS/extract-frames.sh" offset.ts "$OUT" 2
check "times start at zero despite the offset" jt "$M" 'd["grids"][0]["start_seconds"] < 0.1'
check "cuts are reported in player time" jt "$M" 'len(d["scene_change_times"]) == 2 and abs(d["scene_change_times"][0] - 4) < 0.2 and abs(d["scene_change_times"][1] - 8) < 0.2'
KEY2="$(find "$OUT/key_frames" -name 'scene_02_*.jpg' 2>/dev/null | head -n 1)"
check "key frame at the 8s cut shows the new scene" is_blue "$KEY2"
check "relative name containing a colon" bash "$SCRIPTS/extract-frames.sh" "12:30 talk.mp4" "$OUT" 1
check "relative name starting with a dash" bash "$SCRIPTS/extract-frames.sh" "-dash.mp4" "$OUT" 1

check "frame cap run succeeds" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 10 20 auto 4x4
eq "cap limits sampled frames" "$(j "$M" 'd["total_frames_extracted"]')" "20"
eq "cap limits grids too" "$(count "$OUT" 'grid_*.jpg')" "2"

check "static video (no cuts) succeeds" bash "$SCRIPTS/extract-frames.sh" static.mp4 "$OUT" 1 0 auto 4x4
eq "no scene changes in a static video" "$(j "$M" 'd["scene_changes"]')" "0"
check "no key_frames directory without cuts" test ! -d "$OUT/key_frames"

check "scene threshold is adjustable" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 1 0 auto 4x4 "" "" 0.99
eq "very high threshold finds nothing" "$(j "$M" 'd["scene_changes"]')" "0"

check "portrait run succeeds" bash "$SCRIPTS/extract-frames.sh" portrait.mp4 "$OUT" 2 0 auto 5x2
PW="$(image_size "$OUT/grid_001.jpg" | cut -dx -f1)"
PH="$(image_size "$OUT/grid_001.jpg" | cut -dx -f2)"
check "portrait grid fits within 2000px" test "$PW" -le 2000 -a "$PH" -le 2000
eq "portrait grid holds 10 frames" "$(j "$M" 'd["grids"][0]["frames"]')" "10"

check "auto stream skips the thumbnail" bash "$SCRIPTS/extract-frames.sh" thumb.mp4 "$OUT" 1 0 auto 4x4
eq "stream index recorded" "$(j "$M" 'd["video_stream_index"]')" "1"
eq "resolution comes from the real stream" "$(j "$M" 'd["resolution"]')" "640x360"

VA_KEEP_FRAMES=1 bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 1 0 auto 4x4 >/dev/null 2>&1
eq "VA_KEEP_FRAMES writes individual frames" "$(count "$OUT" 'frame_*.jpg')" "12"

refute "rejects filter injection in fps" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" "2,drawtext=text=x"
refute "rejects zero fps" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 0
refute "rejects a bad grid layout" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 2 0 auto 4by4
refute "rejects a bad threshold" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 2 0 auto 4x4 "" "" "0.3:x"
refute "rejects a start past the end" bash "$SCRIPTS/extract-frames.sh" "$CLIP" "$OUT" 2 0 auto 4x4 50 60
refute "rejects a missing file" bash "$SCRIPTS/extract-frames.sh" "$WORK/absent.mp4" "$OUT" 2

# ---------------------------------------------------------- extract-audio --
section "extract-audio.sh"
AOUT="$WORK/audio out"
check "audio extraction succeeds" env WHISPER_BACKEND=none bash "$SCRIPTS/extract-audio.sh" "$CLIP" "$AOUT" base
A="$AOUT/audio_metadata.json"
check "wav written" test -s "$AOUT/audio.wav"
eq "metadata reports audio" "$(j "$A" 'd["has_audio"]')" "True"
eq "transcription skipped with backend none" "$(j "$A" 'd["transcribed"]')" "False"
check "volume analysis written" test -s "$AOUT/volume.txt"

echo "stale" > "$AOUT/transcript.txt"
check "time range run succeeds" env WHISPER_BACKEND=none bash "$SCRIPTS/extract-audio.sh" "$CLIP" "$AOUT" base 4 8
WAV_SECONDS="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AOUT/audio.wav")"
check "wav covers only the range (${WAV_SECONDS}s)" python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - 4) < 0.3 else 1)' "$WAV_SECONDS"
eq "offset recorded" "$(j "$A" 'd["time_offset_seconds"]')" "4"
check "stale transcript removed" test ! -e "$AOUT/transcript.txt"

check "video without audio exits cleanly" env WHISPER_BACKEND=none bash "$SCRIPTS/extract-audio.sh" portrait.mp4 "$AOUT" base
eq "metadata reports no audio" "$(j "$A" 'd["has_audio"]')" "False"
check "no wav for a silent video" test ! -e "$AOUT/audio.wav"

check "relative name containing a colon" env WHISPER_BACKEND=none bash "$SCRIPTS/extract-audio.sh" "12:30 talk.mp4" "$AOUT"
eq "audio found for the colon name" "$(j "$A" 'd["has_audio"]')" "True"
check "relative name starting with a dash" env WHISPER_BACKEND=none bash "$SCRIPTS/extract-audio.sh" "-dash.mp4" "$AOUT"
eq "audio found and source recorded for the dash name" "$(j "$A" 'd["has_audio"], d["source"]')" "(True, '-dash.mp4')"

refute "rejects an unknown backend" env WHISPER_BACKEND=cloud bash "$SCRIPTS/extract-audio.sh" "$CLIP" "$AOUT"
refute "rejects a bad model name" env WHISPER_BACKEND=none bash "$SCRIPTS/extract-audio.sh" "$CLIP" "$AOUT" 'base;ls'
refute "rejects a missing file" bash "$SCRIPTS/extract-audio.sh" "$WORK/absent.mp4" "$AOUT"

# Stand-in whisper CLIs, so backend handling is tested without models or network.
FAKE="$WORK/fakebin"
mkdir -p "$FAKE/modern" "$FAKE/legacy" "$FAKE/broken"
cat > "$FAKE/modern/whisper" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "--help" ]]; then echo "usage: whisper [--output_format {txt,json,all}] audio"; exit 0; fi
while [[ $# -gt 0 ]]; do [[ "$1" == "--output_dir" ]] && dir="$2"; shift; done
echo '{"language": "en", "segments": [{"start": 0.5, "end": 2.0, "text": " fake modern words"}]}' > "$dir/audio.json"
SH
cat > "$FAKE/legacy/whisper" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "--help" ]]; then echo "usage: whisper [--output_dir DIR] audio"; exit 0; fi
for arg in "$@"; do [[ "$arg" == "--output_format" ]] && { echo "unrecognized arguments" >&2; exit 2; }; done
while [[ $# -gt 0 ]]; do [[ "$1" == "--output_dir" ]] && dir="$2"; shift; done
printf '1\n00:00:00,500 --> 00:00:02,000\nfake legacy words\n' > "$dir/audio.wav.srt"
SH
cat > "$FAKE/broken/whisper" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "--help" ]]; then echo "usage: whisper [--output_format {txt,json,all}] audio"; exit 0; fi
echo "Traceback: tokenizer exploded" >&2; exit 1
SH
chmod +x "$FAKE"/*/whisper

check "modern whisper CLI" env PATH="$FAKE/modern:$PATH" WHISPER_BACKEND=openai bash "$SCRIPTS/extract-audio.sh" "$CLIP" "$AOUT" base 4 8
eq "JSON transcript shifted to absolute time" "$(cat "$AOUT/transcript.txt" 2>/dev/null)" "[00:00:04.500 - 00:00:06.000] fake modern words"
eq "language recorded" "$(j "$A" 'd["language"]')" "en"

check "legacy whisper CLI without --output_format" env PATH="$FAKE/legacy:$PATH" WHISPER_BACKEND=openai bash "$SCRIPTS/extract-audio.sh" "$CLIP" "$AOUT" base
eq "SRT fallback transcript" "$(cat "$AOUT/transcript.txt" 2>/dev/null)" "[00:00:00.500 - 00:00:02.000] fake legacy words"

env PATH="$FAKE/broken:$PATH" WHISPER_BACKEND=openai bash "$SCRIPTS/extract-audio.sh" "$CLIP" "$AOUT" base >/dev/null 2>&1
eq "failed transcription exits with code 3" "$?" "3"
eq "failure recorded in metadata" "$(j "$A" 'd["transcribed"], bool(d["transcription_error"])')" "(False, True)"
check "audio is still extracted when transcription fails" test -s "$AOUT/audio.wav"
check "no transcript left behind on failure" test ! -e "$AOUT/transcript.txt"

if [[ "${RUN_WHISPER_TESTS:-0}" == "1" ]] && command -v say >/dev/null; then
    section "transcription (RUN_WHISPER_TESTS=1)"
    say -o speech.aiff "The quick brown fox jumps over the lazy dog."
    gen -f lavfi -i "color=c=black:d=5:s=320x180:r=10" -i speech.aiff \
        -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest speech.mp4
    if WHISPER_MLX_MODEL="${WHISPER_MLX_MODEL:-mlx-community/whisper-tiny}" \
       bash "$SCRIPTS/extract-audio.sh" speech.mp4 "$AOUT" tiny >/dev/null 2>&1; then
        ok "transcription run succeeds"
    else
        bad "transcription run succeeds"
    fi
    eq "metadata reports a transcript" "$(j "$A" 'd["transcribed"]')" "True"
    check "transcript mentions the fox" grep -qi "fox" "$AOUT/transcript.txt"
    check "transcript lines carry timestamps" grep -Eq '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} - ' "$AOUT/transcript.txt"
else
    echo "  skip real transcription (set RUN_WHISPER_TESTS=1 on macOS to run it)"
fi

# ------------------------------------------------------ extract-subtitles --
section "extract-subtitles.sh"
SOUT="$WORK/subs out"
check "subtitle extraction succeeds" bash "$SCRIPTS/extract-subtitles.sh" subs.mp4 "$SOUT" 0
check "cue text extracted" grep -q "Hello from the subtitle track" "$SOUT/subtitles.srt"
cp subs.mp4 "1:2 subs.mp4"
check "relative name containing a colon" bash "$SCRIPTS/extract-subtitles.sh" "1:2 subs.mp4" "$SOUT" 0
refute "rejects a missing subtitle stream" bash "$SCRIPTS/extract-subtitles.sh" "$CLIP" "$SOUT" 0
refute "rejects a non-numeric index" bash "$SCRIPTS/extract-subtitles.sh" subs.mp4 "$SOUT" first

# ---------------------------------------------------------------- summary --
echo ""
echo "Passed: $PASS   Failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
