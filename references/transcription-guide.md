# Transcription Guide

Only non-obvious details. Claude knows how to use Whisper.

## Order of Preference

1. **Existing subtitles** — embedded text streams (`extract-subtitles.sh`) or a sidecar `.srt`/`.vtt` next to the video. Instant, and usually more accurate than re-transcribing.
2. **mlx-whisper** — Apple Silicon only. Runs `whisper-large-v3-turbo` on the GPU.
3. **openai-whisper** — any platform.

`extract-audio.sh` picks between 2 and 3 itself (`WHISPER_BACKEND=auto`): mlx-whisper when `mlx_whisper` is on PATH on Apple Silicon, otherwise the `whisper` CLI, otherwise it skips transcription and says so.

## Backends

| Backend | Install | Model used | Notes |
|---------|---------|------------|-------|
| `mlx` | `uv tool install mlx-whisper` | `mlx-community/whisper-large-v3-turbo` (override with `WHISPER_MLX_MODEL`) | The `whisper_model` argument is ignored. With `WHISPER_BACKEND=mlx` and no install, the script falls back to `uvx --from mlx-whisper`, which downloads the package on first use |
| `openai` | `pip install -U openai-whisper` | The `whisper_model` argument | `base` for long videos (speed), `medium` for short ones (accuracy), `turbo` if the release supports it |
| `none` | — | — | Audio, silence and volume only |

The first run of any model downloads it (tiny ~75 MB, large-v3-turbo ~1.6 GB).

## Gotchas

- Use `transcript.txt`. Its timestamps are absolute video time. Whisper's own `audio.json`/`audio.srt`/`audio.vtt` start at 0 from the beginning of the extracted range (`time_offset_seconds` in `audio_metadata.json`).
- `silence.txt` is also relative to `time_offset_seconds`.
- openai-whisper needs Python 3.10-3.12 (not 3.13+). If the system Python is too new, Whisper may live under an older one (check `which whisper`).
- openai-whisper releases before 2023 have no `--output_format` and no JSON output. The script detects this and builds `transcript.txt` from the `.srt` instead, but the language is then reported as `unknown`. Upgrade when you can.
- A stale openai-whisper can also crash outright against newer dependencies. The script then exits with code `3` and sets `transcription_error` in `audio_metadata.json`; the WAV, silence and volume files are still valid.
- Auto-detection picks the wrong language on short or music-heavy clips. Set `WHISPER_LANGUAGE` (e.g. `pl`) when the language is known.
- Whisper invents text over silence and music ("Thank you for watching"). Cross-check suspicious lines against `silence.txt`.
- Image-based subtitle formats (DVD, Blu-ray PGS) cannot be extracted as text; `video-info.sh` leaves them out of `subtitle_streams`.

## Troubleshooting

- **Exit code 3**: read `transcription_error`, fix or switch backend (`WHISPER_BACKEND=mlx` or `openai`), or continue visual-only
- **Out of memory**: use `base` (openai) or `WHISPER_MLX_MODEL=mlx-community/whisper-base-mlx`
- **Bad accuracy**: set `WHISPER_LANGUAGE`, or use `medium`/`turbo`
- **No audio detected**: `has_audio` is false in `video-info.sh`; `extract-audio.sh` exits 0 with `has_audio: false`
