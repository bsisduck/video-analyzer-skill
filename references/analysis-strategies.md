# Analysis Strategies

Subagent dispatch patterns and token budget guidance.

## Subagent Dispatch

### Short/Medium Videos (detailed)
```
Parallel batch 1: extract-frames.sh + extract-audio.sh
Parallel batch 2:
  ├── Grid agents (1 per 2-3 grids): Read grid images, describe visual content
  ├── Key frame agent: Read high-res key_frames/ for scene-change detail
  └── Audio agent: Read transcription + silence/volume data
Sequential: Synthesize → write analysis document → cleanup
```

### Long/Extended Videos (transcription-focused)
```
Parallel batch 1: extract-frames.sh + extract-audio.sh
Parallel batch 2:
  ├── 1 grid agent (fewer grids)
  └── 1 audio agent (deep transcription analysis)
Sequential: Synthesize → write analysis document → cleanup
```

### Visual-Only (skip mode)
```
Step 1: extract-frames.sh only
Step 2: Grid agents + key frame agent (no audio agent)
Sequential: Synthesize → write analysis document → cleanup
```

## Subagent Prompts

### Grid Analysis Agent Prompt Template

```
Analyze frames from a [duration] video ([width]x[height] [orientation]).
Each grid is a [grid_layout] layout at [fps_rate]fps with timestamps in top-left.

Read these grid images:
- [full path to grid_001.jpg] (frames ~0:00 - 0:XX)
- [full path to grid_002.jpg] (frames ~0:XX - 0:XX)

For each grid provide:
1. Scene description: what is happening visually
2. Key elements: UI, characters, text overlays, objects
3. Visual transitions: scene changes, camera movements
4. Mood/style: colors, lighting, energy level

Output as structured markdown with ## headers per grid time range.
```

### Key Frame Agent Prompt Template

```
Analyze high-res key frames at scene-change moments from a [duration] video.
Each frame has a timestamp burned in the top-left corner.

Scene changes detected at: [list timestamps from scene_changes.txt]

Read ALL key frame files in [key_frames/ directory path].

For each key frame provide:
1. Timestamp and what changed: what visual transition triggered this
2. Detailed description: characters, objects, UI, text (these are high-res)
3. Significance: why this moment matters in the video's narrative
```

## Token Budget Estimates

### Per Image
- Montage grid (3x5 or 4x4, 640px cells): ~1,500-2,500 tokens
- Individual key frame (1280px): ~800-1,200 tokens
- Grid approach saves 60-70% tokens vs individual frames

### By Tier
- Short: ~15K-25K tokens (visual heavy)
- Medium: ~20K-35K tokens (balanced)
- Long: ~15K-25K tokens (transcription heavy)
- Extended: ~20K-30K tokens (transcription dominant)

### Grid Counts by Tier and Orientation
| Tier | Frames | Landscape (4x4=16/grid) | Portrait (3x5=15/grid) |
|------|--------|------------------------|----------------------|
| Short (<1min) | ~120 | ~8 grids | ~8 grids |
| Medium (1-3min) | ~180 | ~12 grids | ~12 grids |
| Long (3-10min) | ~60 | ~4 grids | ~4 grids |
| Extended (10+min) | ≤60 | ~4 grids | ~4 grids |
