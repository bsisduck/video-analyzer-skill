---
name: analyzing-video
description: Analyzes video files by extracting frames, detecting scene changes, and optionally transcribing audio. Produces structured markdown analysis with timeline, visual descriptions, and key moments. Use when the user provides a video file (.mp4, .mov, .avi, .mkv, .webm) and wants analysis, asks to "analyze a video", "describe this video", "video timeline", "what happens in this video", or mentions video content understanding. Supports visual-only mode ("skip audio", "visual only") and user-provided transcripts.
argument-hint: [video-path]
allowed-tools: Bash, Read, Agent
---

# Video Analyzer

Extracts frames at adaptive rates, creates montage grids, detects scene changes, and dispatches parallel subagents for visual and audio analysis.

## Gotchas

- Social media downloads (Instagram, TikTok) embed a MJPEG thumbnail as video stream 0. The scripts auto-detect the real H.264/H.265 stream and skip `attached_pic` streams.
- macOS `grep` lacks `-P` (Perl regex). All scripts use `sed` and basic `grep` for compatibility.
- FFmpeg treats `.` in output filenames as image sequence patterns. Key frame extraction uses `-update 1` to write single images.
- Portrait videos (height > width) use 3x5 grid layout instead of 4x4 for better cell visibility.
- Scene detection threshold is `0.3`. For static content (presentations, documents), lower to `0.1`. For fast action (games, sports), raise to `0.4`.
- Always verify extraction produced output before dispatching analysis agents.

## Prerequisites

Requires `ffmpeg`, `ffprobe`, `python3`, `bc`. For transcription: `whisper` CLI.

```bash
brew install ffmpeg && pip install openai-whisper
```

## Transcription Modes

| Mode | Trigger | Behavior |
|------|---------|----------|
| **auto** | Default | Run Whisper |
| **user-provided** | User supplies transcript file/text | Use provided transcript |
| **skip** | "visual only", "skip audio", "no transcription" | No audio processing |

## Workflow

Copy this checklist and track progress:

```
- [ ] Step 1: Get video info (tier, stream, orientation)
- [ ] Step 2: Extract frames + grids + scene key frames
- [ ] Step 3: Verify extraction output (frames exist, grids exist)
- [ ] Step 4: Dispatch parallel analysis agents
- [ ] Step 5: Synthesize results into analysis document
- [ ] Step 6: Clean up temp directory
```

### Step 1: Get Video Info

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/video-info.sh "$ARGUMENTS"
```

Returns JSON with: `video_stream_index`, `tier`, `fps_rate`, `max_frames`, `orientation`, `grid_layout`, `has_audio`, `work_dir`, `whisper_model`.

| Tier | Duration | Frame Rate | Whisper Model |
|------|----------|-----------|---------------|
| Short | <1 min | 2/sec | medium |
| Medium | 1-3 min | 1/sec | medium |
| Long | 3-10 min | 1/10sec | base |
| Extended | 10+ min | 1/20sec (max 60) | base |

### Step 2: Extract Frames (and Audio)

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/extract-frames.sh "$ARGUMENTS" "<work_dir>/frames" <fps_rate> <max_frames> <stream_index> <grid_layout>
```

For transcription (auto mode only):
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/extract-audio.sh "$ARGUMENTS" "<work_dir>/audio" <whisper_model>
```

Dispatch both in parallel when applicable.

### Step 3: Verify Extraction

Before dispatching agents, verify output:
- Check `<work_dir>/frames/grid_*.jpg` exist (at least 1 grid)
- Check `<work_dir>/frames/metadata.json` for frame count and grid count
- If scene changes detected, check `<work_dir>/frames/key_frames/` has images
- If extraction failed, report error and stop

### Step 4: Parallel Subagent Analysis

Dispatch in parallel:

- **Grid agents** (1 per 2-3 grids): Read montage grid images, describe visual content per time range
- **Key frame agent** (if scene changes detected): Read high-res `key_frames/` images for detailed scene-change analysis
- **Audio agent** (skip if mode is `skip`): Read transcription and audio metadata

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
| Analysis Tier | short/medium/long/extended |
| Frames Analyzed | N |
| Scene Changes | N |
| Transcription | auto/user-provided/skipped |

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

### Step 6: Cleanup

```bash
rm -rf "<work_dir>"
```

## Scripts

| Script | Purpose | Args |
|--------|---------|------|
| `scripts/video-info.sh` | Metadata, stream detection, tier | `<video_path>` |
| `scripts/extract-frames.sh` | Frames, grids, scene detection, key frames | `<video_path> <out_dir> <fps> [max] [stream] [grid]` |
| `scripts/extract-audio.sh` | Audio, silence detection, transcription | `<video_path> <out_dir> [model]` |

## References

- [references/ffmpeg-commands.md](references/ffmpeg-commands.md) — FFmpeg gotchas and non-obvious commands
- [references/transcription-guide.md](references/transcription-guide.md) — Whisper model selection and troubleshooting
- [references/analysis-strategies.md](references/analysis-strategies.md) — Subagent dispatch patterns and output template
