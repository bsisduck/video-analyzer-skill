# Video Analyzer Skill for Claude Code

A video analysis skill for [Claude Code](https://claude.ai/claude-code) that samples frames into timestamped grids, detects scene changes, gets a transcript, and dispatches parallel subagents for visual and audio analysis.

Follows the [Agent Skills](https://agentskills.io) open standard.

## Features

- **Automatic tier selection** — adapts frame rate to the video's duration
- **Custom frame rate & time range** — override defaults with "at 5fps" or "from 0:10 to 0:30"
- **Whole-video coverage under a frame budget** — when a rate would exceed the budget, the rate is lowered instead of cutting the video short
- **Smart stream detection** — skips attached thumbnails common in Instagram/TikTok downloads
- **Orientation-aware grids** — 4x4 landscape, 5x2 portrait, 4x3 square; rotation metadata from phone videos is honored
- **Grids sized for the model** — montages stay at 1920px wide so they are not shrunk before analysis, with readable timestamps on every frame
- **Scene change detection** — adjustable threshold, high-res key frames spread across the whole video
- **Transcript from the best source** — existing subtitles first, then mlx-whisper (Apple Silicon) or openai-whisper
- **Parallel subagent analysis** — grid, key frame, and audio agents run simultaneously
- **Structured output** — a Markdown analysis document with timeline and scene breakdown

## Analysis Tiers

| Tier | Duration | Frame Rate | Focus |
|------|----------|-----------|-------|
| Short | <1 min | 2 frames/sec | Detailed visual + audio |
| Medium | 1-3 min | 1 frame/sec | Detailed with transcription |
| Long | 3-10 min | 1 frame/10sec | Transcription + visual overview |
| Extended | 10+ min | 1 frame/20sec, lowered to fit 60 frames | Transcription-dominant |
| Custom | Any | User-specified, up to 200 frames | User-defined focus |

## Prerequisites

- **ffmpeg** and **ffprobe** — frame extraction, audio processing
- **python3** — metadata and JSON handling (standard library only)
- A Whisper CLI — optional, only needed when the video has no subtitles and you want a transcript

```bash
brew install ffmpeg               # FFmpeg + ffprobe

# transcription, pick one
uv tool install mlx-whisper       # Apple Silicon: fastest
pip install -U openai-whisper     # any platform
```

## Installation

### As a Claude Code skill (recommended)

```bash
git clone https://github.com/bsisduck/video-analyzer-skill.git
cp -r video-analyzer-skill ~/.claude/skills/video-analyzer
chmod +x ~/.claude/skills/video-analyzer/scripts/*.sh
```

Claude Code auto-discovers the skill and activates it when you ask to analyze a video. To update, pull and copy again — or symlink the clone instead of copying so updates apply immediately:

```bash
ln -s "$(pwd)/video-analyzer-skill" ~/.claude/skills/video-analyzer
```

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

### Transcript Sources

```
# Automatic (default): subtitles if the video has them, otherwise Whisper
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

1. **video-info.sh** — picks the real video stream, the tier, the frame rate that fits the frame budget, the grid layout, and reports available subtitles.
2. **extract-frames.sh** — in a single decode: samples frames into montage grids and scores scene changes; then grabs a high-res key frame at each transition.
3. **Transcript** — **extract-subtitles.sh** for embedded subtitles, or **extract-audio.sh** for Whisper transcription plus silence and volume analysis.
4. **Parallel subagents** — grid agents analyze montage grids, a key frame agent analyzes scene-change moments, an audio agent analyzes the transcript.
5. **Synthesis** — merges all results into a structured Markdown analysis document.

## Project Structure

```
video-analyzer-skill/
├── SKILL.md                          # Core skill definition
├── references/
│   ├── ffmpeg-commands.md            # FFmpeg gotchas and non-obvious commands
│   ├── transcription-guide.md        # Transcription backends and troubleshooting
│   └── analysis-strategies.md        # Subagent prompts and token budgets
├── scripts/
│   ├── video-info.sh                 # Metadata, stream detection, analysis plan
│   ├── extract-frames.sh             # Grids, scene detection, key frames
│   ├── extract-audio.sh              # Audio extraction, silence detection, transcription
│   ├── extract-subtitles.sh          # Embedded subtitles to SRT
│   └── vahelper.py                   # Shared logic: stream selection, JSON, time maths
└── tests/
    ├── run-tests.sh                  # End-to-end tests on synthetic videos
    └── test_vahelper.py              # Unit tests
```

## Scripts (standalone usage)

Scripts can be used independently outside Claude Code:

```bash
# Get video metadata and the analysis plan (JSON)
bash scripts/video-info.sh video.mp4

# With custom fps and time range
bash scripts/video-info.sh video.mp4 5 10 30

# Time range only (empty fps keeps the tier default)
bash scripts/video-info.sh video.mp4 "" 0:10 0:30

# Extract grids (2fps, auto stream, landscape grid)
bash scripts/extract-frames.sh video.mp4 /tmp/output 2 0 auto 4x4

# With a time range (0:10 to 0:30) and a more sensitive scene threshold
bash scripts/extract-frames.sh video.mp4 /tmp/output 2 0 auto 4x4 10 30 0.1

# Also keep the individual frames
VA_KEEP_FRAMES=1 bash scripts/extract-frames.sh video.mp4 /tmp/output 2

# Extract audio and transcribe
bash scripts/extract-audio.sh video.mp4 /tmp/audio medium

# Transcribe a range, forcing the backend and language
WHISPER_BACKEND=mlx WHISPER_LANGUAGE=pl bash scripts/extract-audio.sh video.mp4 /tmp/audio medium 10 30

# Extract the first embedded subtitle stream
bash scripts/extract-subtitles.sh video.mkv /tmp/subs 0
```

Each script documents its arguments, environment variables, and exit codes in its header.

## Development

```bash
bash tests/run-tests.sh                        # lint + unit + end-to-end, no network
RUN_WHISPER_TESTS=1 bash tests/run-tests.sh    # also run a real transcription (macOS)
```

The tests generate their own sample videos with ffmpeg.

## Supported Formats

`.mp4`, `.mov`, `.avi`, `.mkv`, `.webm` — anything FFmpeg can decode.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
