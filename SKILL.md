---
name: analyzing-video
description: Analyzes video files by extracting frames, detecting scene changes, and optionally transcribing audio. Produces structured markdown analysis with timeline, visual descriptions, and key moments. Use when the user provides a video file (.mp4, .mov, .avi, .mkv, .webm) and wants analysis, asks to "analyze a video", "describe this video", "video timeline", "what happens in this video", or mentions video content understanding. Supports custom frame rates ("at 5fps", "1 frame every 3 seconds"), time ranges ("from 0:10 to 0:30", "first 15 seconds"), visual-only mode ("skip audio"), and user-provided transcripts.
argument-hint: [video-path] [options]
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*) Read Agent
---

# Video Analyzer

Samples frames at an adaptive rate into timestamped montage grids, detects scene changes, gets a transcript (existing subtitles first, Whisper second), and dispatches parallel subagents for visual and audio analysis.

**Request:** $ARGUMENTS

The request above (or the conversation, if it is empty) contains the video path and may contain options such as a frame rate, a time range, or "visual only". Extract the path first; never pass the whole request string to a script.

## Gotchas

- Social media downloads (Instagram, TikTok) carry a thumbnail as an extra video stream. `video-info.sh` reports the real stream as `video_stream_index`, an **absolute** stream index — pass it through unchanged.
- Phone videos are often stored rotated. Trust `orientation` and `grid_layout` from `video-info.sh` rather than the raw width and height.
- Timestamps burned into grids and key frames, and the times in `transcript.txt`, are always absolute video time, including when a time range is used.
- Whisper's own files (`audio.json`, `audio.srt`) are relative to the range start. Use `transcript.txt`.
- When the requested rate would exceed the frame budget (200 frames, 60 for videos over 10 minutes), `video-info.sh` lowers `fps_rate` so the frames still cover the whole range, and sets `fps_capped: true`. Tell the user the effective rate; suggest a time range if they need the denser sampling.
- Scene detection threshold defaults to `0.3`. For static content (presentations, screen recordings) use `0.1`; for fast action (games, sports) use `0.4`.
- Scripts clear their own previous output, so re-running into the same work directory is safe.
- Always verify extraction produced output before dispatching analysis agents.

## Prerequisites

Requires `ffmpeg`, `ffprobe`, `python3`. Transcription is optional and needs one of:

```bash
uv tool install mlx-whisper      # Apple Silicon: fastest, uses whisper-large-v3-turbo
pip install -U openai-whisper    # any platform
```

## Transcript Sources

Pick the first that applies:

| Mode | When | Behavior |
|------|------|----------|
| **user-provided** | User supplies a transcript file or text | Use it as given |
| **skip** | "visual only", "skip audio", "no transcription" | No audio processing |
| **subtitles** | `has_subtitles` is true | Read `sidecar_subtitles[0]`, or run `extract-subtitles.sh` for an embedded stream. No Whisper needed |
| **auto** | `has_audio` is true | Run `extract-audio.sh` |
| **none** | No audio and no subtitles | Visual-only analysis |

Subtitles and user transcripts carry no silence or volume data. Run `extract-audio.sh` with `WHISPER_BACKEND=none` as well if that matters for the request.

## Customization

Detect these overrides from the user's request:

| Override | User Says | Effect |
|----------|-----------|--------|
| **Custom FPS** | "at 5fps", "3 frames per second", "1 frame every 2 seconds" | Override tier-based fps rate |
| **Time range** | "from 0:10 to 0:30", "first 15 seconds", "last minute" | Analyze only the specified segment |
| **Both** | "analyze 0:10-0:30 at 5fps" | Custom fps on a segment |
| **Language** | "it's in Polish" | `WHISPER_LANGUAGE=pl` for `extract-audio.sh` |

Convert user phrasing to script parameters:
- "5fps" / "5 frames per second" → fps_override=`5`
- "1 frame every 3 seconds" → fps_override=`0.333`
- "from 0:10 to 0:30" → start_time=`10` end_time=`30` (`0:10` and `00:00:10` also work)
- "first 15 seconds" → start_time=`0` end_time=`15`
- "last 30 seconds" → run `video-info.sh` once for the duration, then start_time=`duration-30`

Pass `""` for an argument you want to leave at its default (for example, a time range without a custom fps).

## Workflow

Copy this checklist and track progress:

```
- [ ] Step 1: Get video info (tier, stream, grid layout, transcript source)
- [ ] Step 2: Extract grids + scene key frames, and the transcript
- [ ] Step 3: Verify extraction output
- [ ] Step 4: Dispatch parallel analysis agents
- [ ] Step 5: Synthesize results into analysis document
- [ ] Step 6: Clean up the work directory
```

### Step 1: Get Video Info

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/video-info.sh "<video_path>" [fps_override] [start_time] [end_time]
```

Returns JSON. The fields that drive the next steps: `video_stream_index`, `fps_rate`, `max_frames`, `grid_layout`, `start_time`, `end_time`, `time_range_set`, `has_audio`, `has_subtitles`, `subtitle_streams`, `sidecar_subtitles`, `whisper_model`, `work_dir`, `fps_capped`, `expected_grids`.

| Tier | Duration | Frame Rate | Whisper Model |
|------|----------|-----------|---------------|
| Short | <1 min | 2/sec | medium |
| Medium | 1-3 min | 1/sec | medium |
| Long | 3-10 min | 1/10sec | base |
| Extended | 10+ min | 1/20sec, lowered to fit 60 frames | base |

Tiers are chosen from the effective duration (the time range, if one is set). The Whisper model column applies to the openai-whisper backend; mlx-whisper always uses `whisper-large-v3-turbo`.

### Step 2: Extract Frames and Transcript

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/extract-frames.sh "<video_path>" "<work_dir>/frames" <fps_rate> <max_frames> <video_stream_index> <grid_layout> [start_time] [end_time] [scene_threshold]
```

Only pass `start_time`/`end_time` when `time_range_set` is true.

Transcript, depending on the source chosen above:

```bash
# auto
bash ${CLAUDE_SKILL_DIR}/scripts/extract-audio.sh "<video_path>" "<work_dir>/audio" <whisper_model> [start_time] [end_time]
# embedded subtitles
bash ${CLAUDE_SKILL_DIR}/scripts/extract-subtitles.sh "<video_path>" "<work_dir>/subs" <subtitle_index>
```

Run frame extraction and the transcript step in parallel.

`extract-audio.sh` exit codes: `0` success (also when there is no audio or no transcription tool — check `transcribed` in `audio_metadata.json`), `3` audio extracted but transcription failed. On `3`, or when `transcribed` is false, continue with visual-only analysis and tell the user why there is no transcript.

### Step 3: Verify Extraction

Read `<work_dir>/frames/metadata.json`:
- `montage_grids` is at least 1 and the `grid_*.jpg` files exist
- `grids[]` lists each grid file with the `start`/`end` timestamps it covers
- `key_frames[]` lists the scene-change images in `key_frames/` (absent when there are no cuts)
- If extraction failed, report the error and stop

### Step 4: Parallel Subagent Analysis

Dispatch in parallel, giving each agent absolute file paths:

- **Grid agents** (1 per 2-3 grids): read montage grids and describe visual content per time range. Give each agent its grids' `start`/`end` from `metadata.json`.
- **Key frame agent** (only if `key_frames` is non-empty): read the high-res `key_frames/` images for scene-change detail.
- **Audio agent** (only if there is a transcript): read `transcript.txt` (or the subtitle file), plus `silence.txt` and `volume.txt` when present.

Pass the user's actual question to every agent so they look for what matters, not just a generic description. Prompt templates are in [references/analysis-strategies.md](references/analysis-strategies.md).

If the user asked about a specific moment and the grids are too coarse to answer, re-run Steps 1-2 on a narrow time range at a higher fps rather than guessing.

### Step 5: Synthesize and Output

Merge all agent results into `<video_name>_analysis.md` next to the source video:

```markdown
# Video Analysis: [filename]

## Overview
| Property | Value |
|----------|-------|
| Duration | HH:MM:SS |
| Resolution | WxH |
| Orientation | portrait/landscape |
| Analysis Tier | short/medium/long/extended/custom |
| Range Analyzed | full / HH:MM:SS - HH:MM:SS |
| Frames Analyzed | N (at X fps) |
| Scene Changes | N |
| Transcript | whisper (backend, model) / subtitles / user-provided / none |

## Executive Summary
[2-3 paragraph summary]

## Timeline
| Time | Visual | Audio/Speech |
|------|--------|-------------|
| 00:00 | [description] | [what is said/heard] |

## Detailed Scene Analysis
### Scene 1: [Title] (00:00 - 00:15)
**Visual**: [description]
**Audio**: [what is heard]
**Context**: [significance]

## Conclusions
[Overall analysis]
```

State observations and inferences separately, and note anything that could not be determined (no transcript, unreadable text, sampling too sparse).

### Step 6: Cleanup

```bash
rm -rf "<work_dir>"
```

## Scripts

| Script | Purpose | Args |
|--------|---------|------|
| `scripts/video-info.sh` | Metadata, stream detection, tier, grid layout | `<video_path> [fps_override] [start] [end]` |
| `scripts/extract-frames.sh` | Grids, scene detection, key frames | `<video_path> <out_dir> <fps> [max] [stream] [grid] [start] [end] [scene_threshold]` |
| `scripts/extract-audio.sh` | Audio, silence detection, transcription | `<video_path> <out_dir> [model] [start] [end]` |
| `scripts/extract-subtitles.sh` | Embedded subtitles to SRT | `<video_path> <out_dir> [subtitle_index]` |

Environment switches: `VA_KEEP_FRAMES=1` (also write individual `frame_*.jpg`), `WHISPER_BACKEND=auto|mlx|openai|none`, `WHISPER_MLX_MODEL`, `WHISPER_LANGUAGE`.

## References

- [references/ffmpeg-commands.md](references/ffmpeg-commands.md) — FFmpeg gotchas and non-obvious commands
- [references/transcription-guide.md](references/transcription-guide.md) — Transcription backends, models, and troubleshooting
- [references/analysis-strategies.md](references/analysis-strategies.md) — Subagent dispatch patterns, prompt templates, token budgets
