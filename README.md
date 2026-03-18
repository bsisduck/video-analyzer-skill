# Video Analyzer Skill for Claude Code

A video analysis skill for [Claude Code](https://claude.ai/claude-code) that extracts frames, detects scene changes, transcribes audio, and dispatches parallel subagents for visual and audio analysis.

Follows the [Agent Skills](https://agentskills.io) open standard.

## Features

- **Automatic tier selection** — adapts frame rate based on video duration
- **Custom frame rate & time range** — override defaults with "at 5fps" or "from 0:10 to 0:30"
- **Smart stream detection** — skips attached thumbnails common in Instagram/TikTok downloads
- **Portrait-aware grids** — 3x5 layout for portrait, 4x4 for landscape
- **Scene change detection** — auto-detects visual transitions, extracts high-res key frames
- **Parallel subagent analysis** — dispatches grid + key frame + audio agents simultaneously
- **Three transcription modes** — automatic (Whisper), user-provided, or visual-only
- **Structured output** — produces a Markdown analysis document with timeline and scene breakdown

## Analysis Tiers

| Tier | Duration | Frame Rate | Focus |
|------|----------|-----------|-------|
| Short | <1 min | 2 frames/sec | Detailed visual + audio |
| Medium | 1-3 min | 1 frame/sec | Detailed with transcription |
| Long | 3-10 min | 1 frame/10sec | Transcription + visual overview |
| Extended | 10+ min | 1 frame/20sec (max 60) | Transcription-dominant |
| Custom | Any | User-specified | User-defined focus |

## Prerequisites

- **ffmpeg** and **ffprobe** — frame extraction, audio processing
- **python3** and **bc** — metadata parsing (pre-installed on macOS)
- **whisper** CLI — audio transcription (optional, only for auto transcription mode)

```bash
brew install ffmpeg          # FFmpeg + ffprobe
pip install openai-whisper   # Whisper CLI (optional)
```

## Installation

### As a Claude Code skill (recommended)

```bash
git clone https://github.com/bsisduck/video-analyzer-skill.git
cp -r video-analyzer-skill ~/.claude/skills/video-analyzer
chmod +x ~/.claude/skills/video-analyzer/scripts/*.sh
```

Claude Code auto-discovers the skill and activates it when you ask to analyze a video.

### Via npx skills

```bash
npx skills add bsisduck/video-analyzer-skill
```

## Usage

```
analyze this video: /path/to/video.mp4
```

### Customization

```
# Custom frame rate
analyze this video at 5fps: /path/to/video.mp4

# Time range
analyze from 0:10 to 0:30: /path/to/video.mp4

# Both
analyze 0:10-0:30 at 3 frames per second: /path/to/video.mp4
```

### Transcription Modes

```
# Automatic transcription (default)
analyze this video: /path/to/video.mp4

# Visual only — skip audio
analyze this video, visual only: /path/to/video.mp4

# User-provided transcript
analyze this video using transcript /path/to/transcript.srt: /path/to/video.mp4
```

### Trigger Phrases

The skill activates on:
- "analyze a video", "analyze mp4", "describe this video"
- "what happens in this video", "video timeline"
- "at 5fps", "1 frame every 3 seconds"
- "from 0:10 to 0:30", "first 15 seconds"
- "visual only", "skip audio"

## How It Works

1. **video-info.sh** — detects correct stream (skips thumbnails), determines tier, orientation, grid layout. Accepts optional fps override and time range.
2. **extract-frames.sh** — extracts frames, creates montage grids, detects scene changes, extracts high-res key frames at each transition.
3. **extract-audio.sh** — extracts audio, runs Whisper transcription, detects silence segments.
4. **Parallel subagents** — grid agents analyze montage grids, key frame agent analyzes scene-change moments, audio agent analyzes transcription.
5. **Synthesis** — merges all results into a structured Markdown analysis document.

## Project Structure

```
video-analyzer-skill/
├── SKILL.md                          # Core skill definition
├── references/
│   ├── ffmpeg-commands.md            # FFmpeg gotchas and non-obvious commands
│   ├── transcription-guide.md        # Whisper model selection and troubleshooting
│   └── analysis-strategies.md        # Subagent dispatch patterns and output template
└── scripts/
    ├── video-info.sh                 # Metadata, stream detection, tier classification
    ├── extract-frames.sh             # Frames, grids, scene detection, key frames
    └── extract-audio.sh              # Audio extraction, silence detection, transcription
```

## Scripts (standalone usage)

Scripts can be used independently outside Claude Code:

```bash
# Get video metadata and tier
bash scripts/video-info.sh video.mp4

# With custom fps and time range
bash scripts/video-info.sh video.mp4 5 10 30

# Extract frames (2fps, auto stream, portrait grid)
bash scripts/extract-frames.sh video.mp4 /tmp/output 2 0 auto 3x5

# Extract frames with time range (0:10 to 0:30)
bash scripts/extract-frames.sh video.mp4 /tmp/output 2 0 auto 3x5 10 30

# Extract audio and transcribe with medium model
bash scripts/extract-audio.sh video.mp4 /tmp/audio medium
```

## Supported Formats

`.mp4`, `.mov`, `.avi`, `.mkv`, `.webm` — anything FFmpeg can decode.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
