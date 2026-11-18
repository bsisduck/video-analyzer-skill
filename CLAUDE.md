# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code skill (Agent Skills standard), not an application. The "program" is `SKILL.md` — a prompt that instructs an agent to run three bash scripts and then dispatch subagents. There is no build step, package manifest, or test suite.

The frontmatter name is `analyzing-video`, but the install directory is `video-analyzer` (`~/.claude/skills/video-analyzer`).

## Commands

```bash
# Syntax + lint (no CI; run these by hand after editing scripts)
bash -n scripts/*.sh
shellcheck scripts/*.sh

# Exercise the pipeline against a real video (the only way to test)
bash scripts/video-info.sh video.mp4 [fps_override] [start_time] [end_time]
bash scripts/extract-frames.sh video.mp4 /tmp/out/frames <fps> [max_frames] [stream_index|auto] [grid] [start_time] [end_time]
bash scripts/extract-audio.sh video.mp4 /tmp/out/audio [whisper_model]
```

Runtime dependencies: `ffmpeg`, `ffprobe`, `python3`; `whisper` CLI is optional (the audio script warns and skips transcription if missing).

The installed skill at `~/.claude/skills/video-analyzer` is a **copy**, not a symlink. Edits here do not take effect in Claude Code until re-copied (`cp -r . ~/.claude/skills/video-analyzer`), and the installed copy can be stale relative to this repo.

## Architecture

The data flow is a contract between `SKILL.md` and the scripts — changing one side usually requires changing the other:

1. `video-info.sh` is the decision-maker. It emits JSON (`tier`, `fps_rate`, `max_frames`, `video_stream_index`, `grid_layout`, `whisper_model`, `work_dir`, `has_audio`, …). The agent reads these fields and passes them as positional args to the other scripts. All tier thresholds, the 200-frame cap (60 for the extended tier), portrait → `3x5` / otherwise `4x4` grid selection, and the `/tmp/video-analysis-<basename>` work dir live here.
2. `extract-frames.sh` runs separate ffmpeg passes over the input: individual frames (1280px, timestamp burned in), montage grids (640px cells, `tile=` filter), scene detection (`scene` > 0.3 → `scene_changes.txt`), then one high-res key frame per scene change (capped at 20). It writes `metadata.json`, which SKILL.md Step 3 uses to verify extraction.
3. `extract-audio.sh` produces 16kHz mono WAV, silence/volume reports, and Whisper output in all formats.
4. SKILL.md Steps 4–5 fan out grid / key-frame / audio subagents over those files and synthesize `<video_name>_analysis.md` next to the source video. Prompt templates and token budgets for the subagents are in `references/analysis-strategies.md`.

`references/*.md` are loaded on demand by the skill (progressive disclosure) and deliberately contain only non-obvious material — keep them that way rather than documenting standard ffmpeg/Whisper usage.

## Things that must stay in sync

- **Stream auto-detection** (skip `attached_pic` and frame-rate-less MJPEG thumbnail streams, common in Instagram/TikTok downloads) is duplicated as an inline `python3 -c` block in `video-info.sh`, `extract-frames.sh`, and `references/ffmpeg-commands.md`. They have already drifted: only `video-info.sh` also skips `still_image`.
- **Script signatures** are documented in four places: each script's header comment and `${1:?Usage…}` string, the SKILL.md "Customization" section and "Scripts" table, and README "Scripts (standalone usage)". The SKILL.md Scripts table currently omits the fps/time-range args.
- **Tier table** appears in `video-info.sh` (source of truth), SKILL.md, README, and `references/analysis-strategies.md`.

## Constraints and known gaps

- Scripts must run on macOS's stock tools and on Windows Git Bash: no `grep -P` (use `sed`), no `bc` (replaced with `python3`; README/SKILL.md prerequisites still list `bc`). The `PATH="$HOME/bin:$PATH"` export is intentionally scoped to msys/cygwin.
- Shell values interpolated into `python3 -c` are wrapped in `float('…')` or passed via `sys.argv` to prevent code injection through filenames/args. Preserve this when adding calculations.
- `video_stream_index` is an **absolute** stream index, used as `-map 0:<index>`. Don't use it with `v:<n>` specifiers (`extract-frames.sh`'s resolution probe does, which is wrong for files where the video isn't the first video stream).
- `$MAP_ARG`, `$TIME_ARGS`, `$FRAME_LIMIT` are intentionally unquoted for word splitting.
- Time range is only honored by `video-info.sh` and `extract-frames.sh`. `extract-audio.sh` takes no start/end, so a segment analysis still transcribes the whole file, with timestamps relative to the full video.
- Key-frame filenames contain decimal timestamps; `-update 1` is required so ffmpeg doesn't treat the name as an image sequence pattern.
- The scene threshold (`0.3`) is hardcoded in `extract-frames.sh`; SKILL.md tells the agent to tune it for static/fast content, but there is no parameter for it.
- `.gitignore` ignores `*.analysis.md`, but the skill writes `<name>_analysis.md`, so generated analyses are not actually ignored.
