# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code skill (Agent Skills standard), not an application. The "program" is `SKILL.md` — a prompt that instructs an agent to run the scripts in `scripts/` and then dispatch subagents. There is no build step or package manifest.

The frontmatter name is `analyzing-video`, but the install directory is `video-analyzer` (`~/.claude/skills/video-analyzer`). Both invoke the skill.

## Commands

```bash
bash tests/run-tests.sh                              # everything: bash -n, shellcheck, unit, end-to-end
RUN_WHISPER_TESTS=1 bash tests/run-tests.sh          # plus one real transcription (macOS, needs a whisper CLI)
python3 -m unittest discover -s tests                # unit tests only
python3 -m unittest tests.test_vahelper.ScenePickTest  # a single test class
shellcheck scripts/*.sh tests/run-tests.sh
```

The end-to-end tests build synthetic videos with ffmpeg lavfi sources, so they need no sample files or network. Transcription backends are tested with fake `whisper` executables placed on `PATH`. There is no CI; run the suite before committing.

To try a change against a real video:

```bash
bash scripts/video-info.sh video.mp4 [fps_override] [start] [end]
bash scripts/extract-frames.sh video.mp4 /tmp/out/frames <fps> [max] [stream|auto] [grid] [start] [end] [scene_threshold]
bash scripts/extract-audio.sh video.mp4 /tmp/out/audio [model] [start] [end]
bash scripts/extract-subtitles.sh video.mp4 /tmp/out/subs [subtitle_index]
```

The installed skill at `~/.claude/skills/video-analyzer` may be a **copy** rather than a symlink. If so, edits here do not take effect in Claude Code until re-copied.

## Architecture

The data flow is a contract between `SKILL.md` and the scripts — changing one side usually requires changing the other.

1. `video-info.sh` is a thin wrapper over `vahelper.py info`, the decision-maker. Its JSON (`tier`, `fps_rate`, `max_frames`, `video_stream_index`, `grid_layout`, `whisper_model`, `work_dir`, `has_subtitles`, …) is read by the agent and passed as positional args to the other scripts.
2. `extract-frames.sh` runs **one** ffmpeg decode with a `split` filter graph: sampled frames → `tile` montage grids, and every frame → scene scoring. It then extracts one key frame per scene change with fast input seeking, and writes `metadata.json` (including which timestamps each grid covers), which SKILL.md Step 3 uses to verify extraction.
3. `extract-audio.sh` produces 16kHz mono WAV, silence/volume reports, and a transcript via whichever Whisper backend is available. `extract-subtitles.sh` is the cheaper alternative when the file already has text subtitles.
4. SKILL.md Steps 4–5 fan out grid / key-frame / audio subagents over those files and synthesize `<video_name>_analysis.md` next to the source video. Prompt templates and token budgets are in `references/analysis-strategies.md`.

`scripts/vahelper.py` (stdlib only) holds everything that needs JSON, floating point, or stream selection, so there is exactly one implementation of each and every JSON file is produced by `json.dump`. Bash scripts call its subcommands; do not reintroduce inline `python3 -c` snippets or heredoc JSON.

`references/*.md` are loaded on demand by the skill (progressive disclosure) and deliberately contain only non-obvious material — keep them that way rather than documenting standard ffmpeg/Whisper usage.

## Invariants

- **Timestamps are player time (0 = first frame) everywhere the agent looks**, including inside a time range: burned into grids and key frames, in `metadata.json`, and in `transcript.txt`. Four things hold this up in `extract-frames.sh` — `-ss`/`-to` before `-i` with `-copyts`; sampling with `select` rather than the `fps` filter (which relabels the nearest frame with the slot time); subtracting the container start offset (`streaminfo` → `START_OFFSET`); and rebuilding exact times from integer pts (`read_pts`). `vahelper.py transcript` adds the range offset for audio. Whisper's own output files are the exception (relative to the range start). The "frame stamped 7.0s" and `offset.ts` tests guard this.
- **`video_stream_index` is an absolute stream index**: `-map 0:<index>`, `[0:<index>]`, `-select_streams <index>`. Never `v:<index>`.
- **The frame budget is enforced by lowering the fps** in `vahelper.py info` (200 frames, 60 for the extended tier), so sampling always spans the whole range. `max_frames` (applied with `trim` inside the filter graph) is only a backstop.
- **Grid layouts keep the montage within 1920px wide** (`choose_grid` in `vahelper.py`, `GRID_TARGET_WIDTH` in `extract-frames.sh`). Larger images are downscaled by the client or API before the model sees them, which is what made the old 3x5 portrait grids unreadable. If you change layouts, update the token table in `references/analysis-strategies.md`.
- **Every value interpolated into an ffmpeg filter graph is validated by regex first** (fps, grid layout, threshold, stream index, times). Keep that when adding parameters.
- **Input paths are made absolute before any ffmpeg/ffprobe/python call.** A relative `12:30 talk.mp4` is parsed as a protocol and `-clip.mp4` as an option.
- **Scripts delete their own previous outputs** at start, because the work dir is deterministic per video path and gets reused.

## Things that must stay in sync

- **Script signatures**: each script's header comment and usage string, the SKILL.md workflow and "Scripts" table, and README "Scripts (standalone usage)".
- **Tier table**: `cmd_info` in `vahelper.py` (source of truth), SKILL.md, README, and `references/analysis-strategies.md`.
- **Text subtitle codec list**: `TEXT_SUBTITLE_CODECS` in `vahelper.py` and the `case` in `extract-subtitles.sh`.

## Constraints

- Scripts must run on macOS's stock bash 3.2 and BSD tools, and on Windows Git Bash: no `grep -P`, no `mapfile`, no `bc`; expand possibly-empty arrays as `${ARR[@]+"${ARR[@]}"}`. The `PATH="$HOME/bin:$PATH"` export is intentionally scoped to msys/cygwin. Windows is not covered by the tests.
- ffmpeg runs with its working directory set to the output dir so `metadata=print:file=` can take a bare filename (paths inside a filter graph need escaping for `:`, `'` and spaces). Input and output paths are made absolute first for that reason.
- `metadata=print` only logs frames that carry metadata, and `select='gt(scene,T)'` leaves the output empty (an ffmpeg error) on videos without cuts. Both are why the graph uses `select='gte(scene,0)'`; see `references/ffmpeg-commands.md`.
- Key frames use a fast input seek and fall back to decoding from the start when the seek yields nothing.
- `-fps_mode vfr` is used when the installed ffmpeg has it, `-vsync vfr` otherwise. Tested on ffmpeg 7.1 only.
- `extract-audio.sh` exits `3` when audio was extracted but transcription failed, and `0` when there is simply no audio or no transcription tool. SKILL.md relies on that distinction.
- Positional arguments are kept backward compatible; new options go at the end or into environment variables (`VA_KEEP_FRAMES`, `WHISPER_BACKEND`, `WHISPER_MLX_MODEL`, `WHISPER_LANGUAGE`).
