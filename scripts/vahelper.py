#!/usr/bin/env python3
"""Shared helpers for the video-analyzer scripts (standard library only).

Everything that needs JSON, floating point maths or stream selection lives
here so the bash scripts share one implementation and always emit valid JSON.

Subcommands:
  info <video> [fps_override] [start] [end]   analysis plan as JSON
  stream <video>                              absolute index of the real video stream
  streaminfo <video> <index|auto> [start]     index, display size, time base, start offset, duration
  seconds <time>                              HH:MM:SS(.ms) | MM:SS | seconds -> seconds
  scenes <raw> <out> [max] [tb] [offset]      clean scene list, print key-frame picks
  frames-meta ...                             write metadata.json for extract-frames.sh
  transcript <json|srt|vtt> <offset> <out>    compact transcript with absolute times
  json <out> <type>:<key>=<value> ...         write a flat JSON object (s/n/b types)
"""

import argparse
from fractions import Fraction
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

# Subtitle codecs ffmpeg can convert to SRT text (bitmap formats such as
# dvd_subtitle or hdmv_pgs_subtitle cannot be used as a transcript).
TEXT_SUBTITLE_CODECS = {"subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"}

FRAME_CAP = 200          # most frames a single analysis will sample
EXTENDED_FRAME_CAP = 60  # tighter cap for the transcription-led extended tier
GRID_TARGET_WIDTH = 1920  # widest grid; stays under client/API downscale limits
MAX_KEY_FRAMES = 20

TIME_RE = re.compile(r"^\d+(\.\d+)?$|^\d+:\d{1,2}(\.\d+)?$|^\d+:\d{1,2}:\d{1,2}(\.\d+)?$")
NUMBER_RE = re.compile(r"^\d+(\.\d+)?$")
PTS_RE = re.compile(r"pts:\s*(-?\d+)\s+pts_time:\s*(-?\d+(?:\.\d+)?(?:e[+-]?\d+)?)")


def die(message, code=1):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(code)


def parse_time(value):
    """Convert HH:MM:SS(.ms), MM:SS(.ms) or plain seconds to float seconds."""
    value = value.strip()
    if not TIME_RE.match(value):
        die(f"invalid time value: {value!r} (use seconds, MM:SS or HH:MM:SS)")
    seconds = 0.0
    for part in value.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def num(value):
    """Plain decimal text without exponent or precision loss on long videos."""
    text = f"{float(value):.6f}".rstrip("0").rstrip(".")
    return text if text not in ("", "-0") else "0"


def format_hms(seconds, millis=True):
    total_ms = int(round(max(0.0, float(seconds)) * 1000))
    if not millis:
        total_ms -= total_ms % 1000
    whole, ms = divmod(total_ms, 1000)
    text = f"{whole // 3600:02d}:{(whole % 3600) // 60:02d}:{whole % 60:02d}"
    return f"{text}.{ms:03d}" if millis else text


def ffprobe(path):
    if not os.path.isfile(path):
        die(f"File not found: {path}")
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json",
             os.path.abspath(path)],
            capture_output=True, text=True, check=False,
        )
    except FileNotFoundError:
        die("ffprobe not found. Install ffmpeg (e.g. brew install ffmpeg).")
    if result.returncode != 0:
        die(f"ffprobe could not read {path}: {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        die(f"ffprobe returned unparseable output for {path}")


def is_thumbnail(stream):
    """Cover art / thumbnail streams that social-media downloads put first."""
    disposition = stream.get("disposition", {})
    if disposition.get("attached_pic", 0) == 1 or disposition.get("still_image", 0) == 1:
        return True
    return stream.get("codec_name") == "mjpeg" and stream.get("avg_frame_rate") == "0/0"


def pick_video_stream(streams):
    """Return the real video stream, skipping thumbnails; None if no video."""
    videos = [s for s in streams if s.get("codec_type") == "video"]
    for stream in videos:
        if not is_thumbnail(stream):
            return stream
    return videos[0] if videos else None


def rotation_of(stream):
    """Display rotation in degrees (phones store portrait video rotated)."""
    for side_data in stream.get("side_data_list", []) or []:
        if "rotation" in side_data:
            try:
                return int(round(float(side_data["rotation"])))
            except (TypeError, ValueError):
                pass
    try:
        return int(stream.get("tags", {}).get("rotate", 0))
    except (TypeError, ValueError):
        return 0


def display_size(stream):
    width, height = int(stream.get("width", 0) or 0), int(stream.get("height", 0) or 0)
    if abs(rotation_of(stream)) % 180 == 90:
        width, height = height, width
    return width, height


def choose_grid(width, height):
    """Pick a tile layout whose montage stays near 1920px on its long edge.

    Larger montages are downscaled before the model sees them, which shrinks
    every cell and makes the burned-in timestamps unreadable.
    Returns (cols, rows).
    """
    aspect = width / height if width and height else 16 / 9
    if aspect < 0.8:        # portrait: 5 wide x 2 tall
        return 5, 2
    if aspect <= 1.25:      # square-ish
        return 4, 3
    return 4, 4             # landscape


def parse_fps(rate):
    try:
        numerator, denominator = rate.split("/")
        return float(numerator) / float(denominator) if float(denominator) else 0.0
    except (ValueError, AttributeError):
        return 0.0


def work_dir_for(path):
    absolute = os.path.abspath(path)
    stem = os.path.splitext(os.path.basename(absolute))[0]
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", stem).strip("_")[:40] or "video"
    digest = hashlib.sha1(absolute.encode("utf-8")).hexdigest()[:8]
    base = "/tmp" if os.path.isdir("/tmp") else tempfile.gettempdir()
    return os.path.join(base, f"video-analysis-{safe}-{digest}")


def sidecar_subtitles(path):
    stem = os.path.splitext(os.path.abspath(path))[0]
    found = []
    for ext in ("srt", "vtt"):
        found.extend(glob.glob(glob.escape(stem) + "." + ext))
        found.extend(glob.glob(glob.escape(stem) + ".*." + ext))
    return sorted(set(found))


def cmd_info(args):
    probe = ffprobe(args.video)
    streams = probe.get("streams", [])
    video = pick_video_stream(streams)
    if video is None:
        die(f"No video stream found in {args.video}")

    try:
        duration = float(probe.get("format", {}).get("duration") or video.get("duration") or 0)
    except (TypeError, ValueError):
        duration = 0.0
    if duration <= 0:
        die(f"Could not determine duration of {args.video}")

    start = parse_time(args.start) if args.start else 0.0
    end = parse_time(args.end) if args.end else duration
    end = min(end, duration)
    if start >= end:
        die(f"Empty time range: start {start:g}s is not before end {end:g}s "
            f"(video is {duration:.1f}s long)")
    effective = end - start

    if effective <= 60:
        tier, fps, model = "short", 2.0, "medium"
        description = "Under 1min: 2 frames/sec, detailed visual+audio analysis"
    elif effective <= 180:
        tier, fps, model = "medium", 1.0, "medium"
        description = "1-3min: 1 frame/sec, detailed analysis with transcription"
    elif effective <= 600:
        tier, fps, model = "long", 0.1, "base"
        description = "3-10min: 1 frame/10sec, transcription-focused analysis"
    else:
        tier, fps, model = "extended", 0.05, "base"
        description = "10min+: 1 frame/20sec, transcription-focused"

    custom_fps = bool(args.fps)
    if custom_fps:
        if not NUMBER_RE.match(args.fps):
            die(f"invalid fps override: {args.fps!r} (use a positive number such as 5 or 0.5)")
        fps = float(args.fps)
        if fps <= 0:
            die("fps override must be greater than 0")
        tier = "custom"
        description = f"Custom: {fps:g} frames/sec (user override)"

    requested_fps = fps
    cap = EXTENDED_FRAME_CAP if tier == "extended" else FRAME_CAP
    expected = max(1, int(effective * fps))
    fps_capped = expected > cap
    max_frames = 0
    if fps_capped:
        # Lower the rate instead of truncating, so the sampled frames still
        # cover the whole range rather than only its beginning.
        fps = cap / effective
        expected = cap
        max_frames = cap
        description += f" (rate lowered to stay within {cap} frames)"

    width, height = display_size(video)
    orientation = "portrait" if height > width else ("landscape" if width > height else "square")
    cols, rows = choose_grid(width, height)

    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)
    subtitles = []
    for position, stream in enumerate(s for s in streams if s.get("codec_type") == "subtitle"):
        if stream.get("codec_name") in TEXT_SUBTITLE_CODECS:
            subtitles.append({
                "subtitle_index": position,
                "stream_index": stream.get("index"),
                "codec": stream.get("codec_name"),
                "language": stream.get("tags", {}).get("language", "und"),
            })
    sidecars = sidecar_subtitles(args.video)

    try:
        filesize = int(probe.get("format", {}).get("size") or 0)
    except (TypeError, ValueError):
        filesize = 0

    info = {
        "file": os.path.basename(args.video),
        "path": args.video,
        "duration_seconds": round(duration, 3),
        "duration_formatted": format_hms(duration, millis=False),
        "effective_duration": round(effective, 3),
        "start_time": num(start),
        "end_time": num(end),
        "time_range_set": bool(args.start or args.end),
        "filesize_bytes": filesize,
        "width": width,
        "height": height,
        "rotation": rotation_of(video),
        "codec": video.get("codec_name", "unknown"),
        "source_fps": round(parse_fps(video.get("r_frame_rate", "0/1")), 2),
        "orientation": orientation,
        "has_audio": audio is not None,
        "audio_stream_index": audio.get("index") if audio else None,
        "video_stream_index": video.get("index", 0),
        "tier": tier,
        "tier_description": description,
        "custom_fps": custom_fps,
        "requested_fps": round(requested_fps, 6),
        "fps_rate": round(fps, 6),
        "fps_capped": fps_capped,
        "expected_frames": expected,
        "max_frames": max_frames,
        "whisper_model": model,
        "grid_layout": f"{cols}x{rows}",
        "frames_per_grid": cols * rows,
        "expected_grids": -(-expected // (cols * rows)),
        "has_subtitles": bool(subtitles or sidecars),
        "subtitle_streams": subtitles,
        "sidecar_subtitles": sidecars,
        "work_dir": work_dir_for(args.video),
    }
    print(json.dumps(info, indent=2, ensure_ascii=False))


def cmd_stream(args):
    video = pick_video_stream(ffprobe(args.video).get("streams", []))
    if video is None:
        die(f"No video stream found in {args.video}")
    print(video.get("index", 0))


def format_start_time(probe):
    """Container start time: timestamps are shifted by it (MPEG-TS, some MOV)."""
    try:
        return float(probe.get("format", {}).get("start_time") or 0)
    except (TypeError, ValueError):
        return 0.0


def cmd_streaminfo(args):
    probe = ffprobe(args.video)
    streams = probe.get("streams", [])
    if args.index == "auto":
        video = pick_video_stream(streams)
    else:
        video = next((s for s in streams if str(s.get("index")) == args.index
                      and s.get("codec_type") == "video"), None)
    if video is None:
        die(f"No video stream {args.index} in {args.video}")
    try:
        duration = float(probe.get("format", {}).get("duration") or 0)
    except (TypeError, ValueError):
        duration = 0.0
    if args.start and duration > 0 and parse_time(args.start) >= duration:
        die(f"start_time {args.start} is past the end of the video ({duration:.1f}s)")
    time_base = video.get("time_base", "")
    if not re.match(r"^\d+/\d+$", time_base) or time_base.endswith("/0"):
        time_base = "0/1"  # unknown: callers fall back to ffmpeg's rounded times
    width, height = display_size(video)
    print("\t".join([str(video.get("index", 0)), str(width), str(height), time_base,
                     num(format_start_time(probe)), num(duration)]))


def cmd_seconds(args):
    print(num(parse_time(args.time)))


def read_pts(path, time_base="0/1", offset=0.0):
    """Frame times logged by ffmpeg's metadata=print, as seconds of video time.

    ffmpeg prints pts_time with six significant digits, which is too coarse to
    seek to on long videos, so the exact value is rebuilt from the integer pts.
    The container start offset is removed so times match what a player shows.
    """
    if not os.path.isfile(path):
        return []
    base = Fraction(time_base)
    offset = float(offset)
    times = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for match in PTS_RE.finditer(handle.read()):
            approx = float(match.group(2))
            exact = float(int(match.group(1)) * base)
            # Trust the exact value only when it agrees with what ffmpeg printed.
            value = exact if base and abs(exact - approx) <= max(0.01, abs(approx) * 1e-4) else approx
            times.append(max(0.0, value - offset))
    return times


def cmd_scenes(args):
    """Write one timestamp per line; print evenly spread key-frame picks."""
    times = sorted(set(read_pts(args.raw, args.time_base, args.offset)))
    with open(args.out, "w", encoding="utf-8") as handle:
        for value in times:
            handle.write(f"{num(value)}\n")
    limit = max(0, args.max_picks)
    if len(times) <= limit:
        picks = times
    elif limit <= 1:
        picks = times[:limit]
    else:
        # Spread picks over the whole list instead of taking the first N,
        # so a video with many cuts is not represented by its opening only.
        step = (len(times) - 1) / (limit - 1)
        picks = [times[round(i * step)] for i in range(limit)]
    for value in picks:
        print(f"{num(value)}\t{format_hms(value)}")


def cmd_frames_meta(args):
    out_dir = args.out_dir
    frame_times = read_pts(args.frames_raw, args.time_base, args.offset)
    cols, rows = (int(part) for part in args.grid.split("x"))
    per_grid = cols * rows
    grid_files = sorted(glob.glob(os.path.join(glob.escape(out_dir), "grid_*.jpg")))
    grids = []
    for index, path in enumerate(grid_files):
        chunk = frame_times[index * per_grid:(index + 1) * per_grid]
        entry = {"file": os.path.basename(path), "frames": len(chunk)}
        if chunk:
            entry["start"] = format_hms(chunk[0])
            entry["end"] = format_hms(chunk[-1])
            entry["start_seconds"] = round(chunk[0], 3)
            entry["end_seconds"] = round(chunk[-1], 3)
        grids.append(entry)

    scenes = []
    if os.path.isfile(args.scene_file):
        with open(args.scene_file, encoding="utf-8") as handle:
            scenes = [float(line) for line in handle if line.strip()]
    key_frames = sorted(
        os.path.basename(p)
        for p in glob.glob(os.path.join(glob.escape(out_dir), "key_frames", "scene_*.jpg"))
    )
    individual = len(glob.glob(os.path.join(glob.escape(out_dir), "frame_*.jpg")))

    metadata = {
        "source": os.path.basename(args.source),
        "duration_seconds": round(float(args.duration), 3),
        "resolution": args.resolution,
        "video_stream_index": int(args.stream),
        "fps_rate": float(args.fps),
        "start_time": args.start or None,
        "end_time": args.end or None,
        "grid_layout": args.grid,
        "grid_cell_width": int(args.cell_width),
        "total_frames_extracted": len(frame_times),
        "individual_frame_files": individual,
        "montage_grids": len(grid_files),
        "grids": grids,
        "scene_threshold": float(args.threshold),
        "scene_changes": len(scenes),
        "scene_change_times": [round(value, 3) for value in scenes],
        "key_frames": key_frames,
        "output_directory": out_dir,
    }
    with open(os.path.join(out_dir, "metadata.json"), "w", encoding="utf-8") as handle:
        json.dump(metadata, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"{len(frame_times)}\t{len(grid_files)}\t{len(scenes)}\t{len(key_frames)}")


CUE_RE = re.compile(
    r"((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})")


def read_cues(path):
    """Parse SRT or WebVTT into (start, end, text) tuples."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        blocks = re.split(r"\n\s*\n", handle.read().replace("\r\n", "\n"))
    cues = []
    for block in blocks:
        lines = block.strip().split("\n")
        for position, line in enumerate(lines):
            match = CUE_RE.search(line)
            if match:
                text = " ".join(part.strip() for part in lines[position + 1:] if part.strip())
                text = re.sub(r"<[^>]+>", "", text).strip()
                start, end = (parse_time(value.replace(",", ".")) for value in match.groups())
                cues.append((start, end, text))
                break
    return cues


def cmd_transcript(args):
    """Flatten a transcript into '[start - end] text' lines with absolute times.

    Accepts Whisper JSON, or SRT/WebVTT (old whisper releases write no JSON).
    """
    source = args.source
    language = "unknown"
    try:
        if source.lower().endswith(".json"):
            with open(source, encoding="utf-8") as handle:
                data = json.load(handle)
            language = data.get("language", "unknown")
            segments = [(float(s.get("start", 0)), float(s.get("end", 0)), str(s.get("text", "")).strip())
                        for s in data.get("segments", [])]
        else:
            segments = read_cues(source)
    except (OSError, ValueError) as error:
        die(f"could not read transcript {source}: {error}")
    offset = float(args.offset)
    lines = [f"[{format_hms(start + offset)} - {format_hms(end + offset)}] {text}"
             for start, end, text in segments if text]
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + ("\n" if lines else ""))
    print(f"{len(lines)}\t{language}")


def cmd_json(args):
    payload = {}
    for item in args.items:
        match = re.match(r"^([snb]):([^=]+)=(.*)$", item, re.S)
        if not match:
            die(f"bad json item: {item!r} (expected <s|n|b>:<key>=<value>)")
        kind, key, value = match.groups()
        if kind == "s":
            payload[key] = value
        elif kind == "b":
            payload[key] = value.lower() == "true"
        else:
            number = float(value)
            payload[key] = int(number) if number.is_integer() else number
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("info")
    p.add_argument("video")
    p.add_argument("fps", nargs="?", default="")
    p.add_argument("start", nargs="?", default="")
    p.add_argument("end", nargs="?", default="")
    p.set_defaults(func=cmd_info)

    p = sub.add_parser("stream")
    p.add_argument("video")
    p.set_defaults(func=cmd_stream)

    p = sub.add_parser("streaminfo")
    p.add_argument("video")
    p.add_argument("index")
    p.add_argument("start", nargs="?", default="")
    p.set_defaults(func=cmd_streaminfo)

    p = sub.add_parser("seconds")
    p.add_argument("time")
    p.set_defaults(func=cmd_seconds)

    p = sub.add_parser("scenes")
    p.add_argument("raw")
    p.add_argument("out")
    p.add_argument("max_picks", nargs="?", type=int, default=MAX_KEY_FRAMES)
    p.add_argument("time_base", nargs="?", default="0/1")
    p.add_argument("offset", nargs="?", default="0")
    p.set_defaults(func=cmd_scenes)

    p = sub.add_parser("frames-meta")
    for name in ("out-dir", "source", "duration", "resolution", "stream", "fps", "grid",
                 "cell-width", "threshold", "frames-raw", "scene-file"):
        p.add_argument(f"--{name}", required=True)
    p.add_argument("--start", default="")
    p.add_argument("--end", default="")
    p.add_argument("--time-base", default="0/1")
    p.add_argument("--offset", default="0")
    p.set_defaults(func=cmd_frames_meta)

    p = sub.add_parser("transcript")
    p.add_argument("source")
    p.add_argument("offset")
    p.add_argument("out")
    p.set_defaults(func=cmd_transcript)

    p = sub.add_parser("json")
    p.add_argument("out")
    p.add_argument("items", nargs="*")
    p.set_defaults(func=cmd_json)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
