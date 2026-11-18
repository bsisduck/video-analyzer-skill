# FFmpeg Gotchas and Non-Obvious Commands

Only commands that are non-obvious or have gotchas. Claude knows standard FFmpeg usage.

## Stream Selection (Critical for Social Media Downloads)

Instagram/TikTok MP4s carry a thumbnail as an extra video stream, sometimes as stream 0. The selection logic lives in one place, `pick_video_stream` in `scripts/vahelper.py`:

```bash
python3 scripts/vahelper.py stream input.mp4    # prints the absolute stream index
```

It skips streams with the `attached_pic` or `still_image` disposition and MJPEG streams with no frame rate. Use the result as an absolute index:

```bash
ffmpeg -i input.mp4 -map 0:1 ...            # correct: absolute index
ffprobe -select_streams 1 ...               # correct: absolute index
ffprobe -select_streams v:1 ...             # WRONG: v:1 means "second video stream"
```

## Seeking: `-ss` Before `-i`, With `-copyts`

```bash
ffmpeg -ss 600 -to 660 -copyts -i input.mp4 ...
```

- `-ss` after `-i` decodes everything from the start and throws it away — minutes of wasted work on a long file.
- `-ss` before `-i` jumps to the position, but resets timestamps to 0. `-copyts` keeps the original timestamps, so burned-in times and scene times stay absolute.
- `-to` before `-i` is also in original time, so `-ss 600 -to 660` is a 60-second window.

## Sampling Frames: `select`, Not `fps`

```bash
select='isnan(prev_selected_t)+gt(floor(t*0.1),floor(prev_selected_t*0.1))'
```

The `fps` filter picks the nearest input frame and **relabels** it with the slot time. At `fps=0.1` the frame stamped `00:00:10` actually shows 00:00:15 — half an interval late, a full minute on a capped two-hour video. The `select` above takes the first frame of each 1/rate slot and keeps its real timestamp, so the burned-in time is the time of the picture. It also always passes the first frame, so a range shorter than one interval still yields a frame instead of an empty-output error.

`select` output is irregularly timed: give the image output `-fps_mode vfr` (`-vsync vfr` before ffmpeg 5.1) or ffmpeg duplicates and drops images to fake a constant rate.

## Container Start Offset

MPEG-TS (and some MOV) files start their timestamps above zero (`format=start_time`, e.g. 1.457). With `-copyts` that offset shows up in every `pts`, while a player — and an input `-ss` — count from zero. Subtract it: `drawtext` takes an offset as the third `pts` argument (`%{pts\:hms\:-1.457}`), and `vahelper.py` removes it from logged times.

## Exact Times From `metadata=print`

`metadata=print` writes `pts_time` with six significant digits, so a cut at 10000.04s is logged as `10000` and a re-seek lands on the frame before the cut. Rebuild the time from the integer `pts` and the stream `time_base` (`read_pts` in `vahelper.py`).

## One Decode, Several Outputs

`extract-frames.sh` splits the decoded stream instead of running ffmpeg three times:

```bash
-filter_complex "[0:1]split=2[grid_in][scene_in];
  [grid_in]select='...',...,tile=4x4[grid];
  [scene_in]select='gte(scene,0)',metadata=print:key=lavfi.scene_score:value=0.3:function=greater:file=scenes_raw.txt[scene]"
-map "[grid]" grid_%03d.jpg -map "[scene]" -f null -
```

## Scene Change Detection

- `select='gt(scene,0.3)'` drops every non-matching frame. On a video with no cuts the output receives nothing and ffmpeg exits with an error. Score every frame with `select='gte(scene,0)'` and let `metadata=print` do the filtering, as above.
- `metadata=print` only logs frames that carry metadata. To log every sampled frame's timestamp, put `select='gte(scene,0)'` in front of it.
- `metadata=print:file=` takes a path inside the filter graph, where `:`, `'` and spaces need escaping. Run ffmpeg from the output directory and use a bare filename instead.
- Threshold `0.3` suits most content; `0.1` for presentations and screen recordings; `0.4` for fast action.

## Frame Limit

`-frames:v N` counts output images, so on a `tile` output it limits grids, not sampled frames. Limit inside the graph instead, right after sampling: `select='...',trim=end_frame=200`.

## Timestamp Overlay

```bash
drawtext=text='%{pts\:hms}':x=6:y=6:fontsize=30:fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=5
```

In a double-quoted shell string, escape the backslash: `%{pts\\:hms}`. Scale the font with the cell (cell width / 16); a fixed small font becomes unreadable once the grid is downscaled.

## Montage Grid Size

```bash
scale='min(480,iw)':-2,tile=4x4    # landscape: 1920x1080
scale='min(384,iw)':-2,tile=5x2    # portrait:  1920x1364
```

Keep the montage at or under 1920px wide. A 3x5 grid of 640px portrait cells is 1920×5690 and gets shrunk to about a third before the model sees it. `-2` keeps dimensions even.

## Key Frame Extraction Gotchas

```bash
ffmpeg -nostdin -ss 12.73 -i input.mp4 -map 0:1 -frames:v 1 -update 1 "scene_01_12_73s.jpg"
```

- `-update 1`: without it ffmpeg treats the filename as an image sequence pattern.
- `-nostdin`: inside a `while read` loop ffmpeg otherwise consumes the loop's input and the loop ends after one iteration.
- A fast seek can produce no frame at all when it lands where the decoder has no keyframe to start from (open-GOP MPEG-TS). `extract-frames.sh` retries with `-ss` after `-i`, which decodes from the start.

## Silence Detection Output Format

```
[silencedetect @ 0x...] silence_start: 5.678
[silencedetect @ 0x...] silence_end: 8.234 | silence_duration: 2.556
```

## Portability

macOS ships BSD tools and bash 3.2: no `grep -P`, no `mapfile`, and an empty array expands as an error under `set -u` (use `${ARR[@]+"${ARR[@]}"}`). Windows Git Bash has no `bc`; do arithmetic in `vahelper.py`.
