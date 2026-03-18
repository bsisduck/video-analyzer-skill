# Video Analyzer Skill for Claude Code

A comprehensive video analysis skill for [Claude Code](https://claude.ai/claude-code) that extracts frames, transcribes audio, and uses parallel subagents for detailed visual and audio analysis.

## Features

- **Automatic tier selection** based on video duration (short/medium/long/extended)
- **Smart stream detection** — skips attached thumbnails common in Instagram/TikTok downloads
- **Portrait-aware grids** — 3x5 layout for portrait, 4x4 for landscape
- **Scene change detection** — FFmpeg-based automatic visual transition detection
- **Key frame extraction** — high-res individual frames at each scene change
- **Parallel subagent analysis** — dispatches multiple agents for visual + audio analysis simultaneously
- **Three transcription modes** — automatic (Whisper), user-provided, or visual-only (skip)
- **Structured output** — generates a comprehensive Markdown analysis document

## Analysis Tiers

| Tier | Duration | Frame Rate | Focus |
|------|----------|-----------|-------|
| Short | <1 min | 2 frames/sec | Detailed visual + audio |
| Medium | 1-3 min | 1 frame/sec | Detailed with transcription |
| Long | 3-10 min | 1 frame/10sec | Transcription + visual overview |
| Extended | 10+ min | 1 frame/20sec (max 60) | Transcription-dominant |

## Prerequisites

- **ffmpeg** and **ffprobe** — frame extraction, audio processing
- **whisper** CLI (OpenAI Whisper) — audio transcription (only needed for auto mode)
- **python3** and **bc** — metadata parsing (pre-installed on macOS)

```bash
brew install ffmpeg          # FFmpeg + ffprobe
pip install openai-whisper   # Whisper CLI (optional)
```

## Installation

### As a Claude Code skill (recommended)

Copy the skill directory to your Claude Code skills folder:

```bash
cp -r video-analyzer-skill ~/.claude/skills/video-analyzer
chmod +x ~/.claude/skills/video-analyzer/scripts/*.sh
```

Claude Code will auto-discover the skill and activate it when you ask to analyze a video.

### As a standalone tool via npx skills

```bash
npx skills add <your-github-username>/video-analyzer-skill
```

## Usage

Once installed, simply ask Claude Code:

```
analyze this video: /path/to/video.mp4
```

### Transcription Modes

```
# Automatic transcription (default)
analyze this video: /path/to/video.mp4

# Visual only (skip audio)
analyze this video, visual only: /path/to/video.mp4

# With your own transcript
analyze this video with this transcript /path/to/transcript.srt: /path/to/video.mp4
```

### Trigger Phrases

The skill activates on phrases like:
- "analyze a video", "analyze mp4"
- "what happens in this video", "describe this video"
- "video timeline", "transcribe and analyze video"
- "analyze video visual only", "extract frames from video"

## Project Structure

```
video-analyzer-skill/
├── SKILL.md                          # Core skill definition (loaded by Claude Code)
├── README.md                         # This file
├── LICENSE                           # GNU GPL v3
├── references/
│   ├── ffmpeg-commands.md            # FFmpeg/ffprobe command reference
│   ├── transcription-guide.md        # Whisper model selection and usage
│   └── analysis-strategies.md        # Parallel analysis architecture and output templates
└── scripts/
    ├── video-info.sh                 # Video metadata, stream detection, tier classification
    ├── extract-frames.sh             # Frame extraction, grids, scene detection, key frames
    └── extract-audio.sh              # Audio extraction, silence detection, transcription
```

## How It Works

1. **video-info.sh** analyzes the video — detects correct stream (skips thumbnails), determines duration tier, orientation, grid layout
2. **extract-frames.sh** extracts frames at the tier-appropriate rate, creates montage grids, detects scene changes, extracts high-res key frames
3. **extract-audio.sh** (if transcription enabled) extracts audio, runs Whisper, detects silence segments
4. **Parallel subagents** analyze grid images (visual overview) and key frames (detailed scene-change moments)
5. **Synthesis** merges all agent results into a unified analysis document

## Supported Formats

Video: `.mp4`, `.mov`, `.avi`, `.mkv`, `.webm` (anything FFmpeg can decode)

## Scripts (standalone usage)

The shell scripts can also be used independently:

```bash
# Get video metadata and tier
bash scripts/video-info.sh /path/to/video.mp4

# Extract frames (2fps, auto stream detection, 3x5 portrait grid)
bash scripts/extract-frames.sh /path/to/video.mp4 /tmp/output 2 0 auto 3x5

# Extract audio and transcribe
bash scripts/extract-audio.sh /path/to/video.mp4 /tmp/audio medium
```

## License

This project is licensed under the GNU General Public License v3.0 — see the [LICENSE](LICENSE) file for details.
