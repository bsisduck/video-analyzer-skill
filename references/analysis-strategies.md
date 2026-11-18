# Analysis Strategies

Subagent dispatch patterns, prompt templates, and token budget guidance.

## Subagent Dispatch

### Short/Medium Videos (detailed)
```
Parallel batch 1: extract-frames.sh + transcript step (subtitles or extract-audio.sh)
Parallel batch 2:
  ├── Grid agents (1 per 2-3 grids): Read grid images, describe visual content
  ├── Key frame agent: Read high-res key_frames/ for scene-change detail
  └── Audio agent: Read transcript.txt + silence/volume data
Sequential: Synthesize → write analysis document → cleanup
```

### Long/Extended Videos (transcription-focused)
```
Parallel batch 1: extract-frames.sh + transcript step
Parallel batch 2:
  ├── 1 grid agent (fewer grids)
  └── 1 audio agent (deep transcript analysis)
Sequential: Synthesize → write analysis document → cleanup
```

### Visual-Only (skip mode, or no audio and no subtitles)
```
Step 1: extract-frames.sh only
Step 2: Grid agents + key frame agent (no audio agent)
Sequential: Synthesize → write analysis document → cleanup
```

### Follow-up on a specific moment
```
Grids too coarse for the question → re-run video-info.sh + extract-frames.sh
on a narrow time range with a higher fps → 1 grid agent on the new grids
```

## Subagent Prompts

Fill the time ranges from `grids[]` in `metadata.json` — do not estimate them. Always include the user's question.

### Grid Analysis Agent Prompt Template

```
Analyze frames from a [duration] video ([width]x[height] [orientation]).
The user wants to know: [user's question, or "a general description"].

Each image is a [grid_layout] montage sampled at [fps_rate] fps. Frames run
left to right, top to bottom. Each frame has its absolute video timestamp in
the top-left corner.

Read these grid images:
- [absolute path to grid_001.jpg] (covers [start] - [end])
- [absolute path to grid_002.jpg] (covers [start] - [end])

For each grid provide:
1. Scene description: what is happening visually
2. Key elements: UI, people, on-screen text, objects
3. Visual transitions: scene changes, camera movements
4. Anything relevant to the user's question, with its timestamp

Quote timestamps exactly as shown on the frames. Say so when text is too small
to read rather than guessing. Output structured markdown with a ## header per
grid time range.
```

### Key Frame Agent Prompt Template

```
Analyze high-resolution key frames taken at scene changes in a [duration] video.
The user wants to know: [user's question, or "a general description"].
Each frame has its absolute video timestamp in the top-left corner.

Scene changes detected at: [scene_change_times from metadata.json]

Read these key frames:
- [absolute paths from key_frames[] in metadata.json]

For each key frame provide:
1. Timestamp and what changed: what visual transition this is
2. Detailed description: people, objects, UI, readable text (these are high-res)
3. Significance: why this moment matters in the video
```

### Audio Agent Prompt Template

```
Analyze the audio track of a [duration] video.
The user wants to know: [user's question, or "a general description"].

Read:
- [absolute path to transcript.txt or the subtitle file] — timestamps are absolute video time
- [absolute path to silence.txt] — silence_start/silence_end, relative to [time_offset_seconds]s
- [absolute path to volume.txt]

Provide: a topic outline with timestamps, notable quotes, speaker changes if
evident, and long silences or loud moments. Flag passages that look like
transcription errors instead of interpreting them.
```

## Token Budget Estimates

An image costs one token per 28×28 pixel patch. Models downscale images above their limit before counting, so the cost depends on the model tier:

| Image | Size | High-res tier (≤4784 tokens, ≤2576px) | Standard tier (≤1568 tokens, ≤1568px) |
|-------|------|---------------------------------------|---------------------------------------|
| Landscape grid 4x4 | 1920×1080 | ~2,700 tokens, 480px cells | ~1,560 tokens, shown at 1456×819 (364px cells) |
| Portrait grid 5x2 | 1920×1364 | ~3,400 tokens, 384px cells | ~1,550 tokens, shown at 1301×924 (260px cells) |
| Square grid 4x3 | 1920×1440 | ~3,600 tokens, 480px cells | ~1,560 tokens, shown at 1270×952 (317px cells) |
| Key frame | long edge 1280 | ~1,200 tokens | ~1,200 tokens |

Grids are capped at 1920px wide on purpose: anything larger is shrunk before the model sees it, which costs detail without saving tokens on the high-res tier.

A grid shows each frame for roughly 100-340 tokens depending on tier and layout, against ~1,200 for the same frame sent on its own.

### Grid Counts by Tier
| Tier | Frames | Landscape (16/grid) | Portrait (10/grid) |
|------|--------|---------------------|--------------------|
| Short (<1min) | up to 120 | up to 8 grids | up to 12 grids |
| Medium (1-3min) | 60-180 | 4-12 grids | 6-18 grids |
| Long (3-10min) | 18-60 | 2-4 grids | 2-6 grids |
| Extended (10+min) | ≤60 | ≤4 grids | ≤6 grids |
| Custom | ≤200 | ≤13 grids | ≤20 grids |

`video-info.sh` reports the exact count as `expected_grids`. Multiply by the per-grid cost above to estimate visual tokens before dispatching agents.
