# FFmpeg Gotchas and Non-Obvious Commands

Only commands that are non-obvious or have gotchas. Claude knows standard FFmpeg usage.

## Stream Selection (Critical for Social Media Downloads)

Instagram/TikTok MP4s embed a MJPEG thumbnail as stream 0. Always detect the real video stream:

```bash
# Auto-detect: skip attached_pic, skip MJPEG with no frame rate
ffprobe -v error -show_streams -of json input.mp4 | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('streams', []):
    if s.get('codec_type') == 'video':
        if s.get('disposition', {}).get('attached_pic', 0) == 1: continue
        if s.get('codec_name') == 'mjpeg' and s.get('avg_frame_rate') == '0/0': continue
        print(s.get('index', 0)); break
"

# Then use -map 0:<index> in all subsequent commands
ffmpeg -i input.mp4 -map 0:1 -vf "fps=2" frames/%05d.jpg
```

## Timestamp Overlay

```bash
# Burns HH:MM:SS.mmm into top-left corner
-vf "drawtext=text='%{pts\:hms}':x=10:y=10:fontsize=28:fontcolor=white:borderw=2:bordercolor=black"
```

Note: In shell scripts, escape the backslash: `%{pts\\:hms}`

## Montage Grid with Tile Filter

```bash
# 4x4 landscape grid (16 frames per image)
-vf "fps=1,scale='min(640,iw)':-2,tile=4x4"

# 3x5 portrait grid (15 frames per image) — better for portrait video
-vf "fps=1,scale='min(640,iw)':-2,tile=3x5"
```

## Scene Change Detection

```bash
# Detect visual transitions (threshold 0.3 = 30% change)
ffmpeg -i input.mp4 -vf "select='gt(scene,0.3)',showinfo" -f null - 2>&1 \
  | grep 'pts_time' | sed 's/.*pts_time:\([0-9.]*\).*/\1/' | grep '^[0-9]'
```

- Threshold `0.3` works for most content
- Lower to `0.1` for presentations/static content
- Raise to `0.4` for fast-action video (games, sports)
- macOS: must use `sed`, not `grep -P`

## Key Frame Extraction Gotcha

FFmpeg treats `.` in output filenames as image sequence patterns. For single-frame extraction with decimal timestamps in the filename, add `-update 1`:

```bash
ffmpeg -i input.mp4 -ss 12.73 -frames:v 1 -update 1 "scene_12_73s.jpg"
```

## Scale Filter

`-2` ensures even dimensions (required by most codecs):
```bash
scale='min(1280,iw)':-2   # Resize to max 1280px wide, auto height (even)
```

## Silence Detection Output Format

```
[silencedetect @ 0x...] silence_start: 5.678
[silencedetect @ 0x...] silence_end: 8.234 | silence_duration: 2.556
```
