# CaptionLab — build & run (for Claude Code on a fresh machine)

Standalone macOS SwiftUI app + CLI reproducing PalmierPro's caption-correction pipeline, plus a Qwen
(MLX) forced-aligner A/B backend. No external Swift package deps (system frameworks only).

## Prerequisites (verify first)
- Apple Silicon Mac (arm64). Target validated on M1 Pro / 16 GB.
- macOS 26.
- FULL Xcode installed (not just CommandLineTools) — the SwiftUI/AVKit macros need the full toolchain.
- `GEMINI_API_KEY` for the content-map / correction / retranscribe / LLM-cut stages (or paste it into the
  in-GUI key field at runtime).

## Build
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```
- If the first build errors on Metal, install the Metal toolchain component and rebuild:
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

## Enable the Qwen (MLX) aligner backend
```bash
./setup.sh
```
Creates `.venv` and installs `mlx-audio` (MLX only, no torch). The Qwen model
`mlx-community/Qwen3-ForcedAligner-0.6B-8bit` auto-downloads on the first alignment run (needs network
once; ~hundreds of MB; ~2.2 GB peak RAM per run — the app serializes aligner runs). Without this the app
still builds and the Apple-ASR path works; the Qwen backend shows a "run ./setup.sh" hint.

## Run
```bash
export GEMINI_API_KEY=…                       # or use the in-GUI field
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run CaptionLab [optional-media-path]
```
GUI: drop videos to build a track → Run pipeline. Switch "Timing backend" to Apple / Qwen / Both to A/B
the two aligners on the timeline. Headless CLI: `swift run CaptionLab --cli <media> [options]`
(`--cli --help` for flags).

## Paths / overrides
The app finds `.venv/bin/python` and `aligner/qwen_align.py` relative to the working dir (repo root under
`swift run`). Override with `CAPTIONLAB_PYTHON` and `CAPTIONLAB_ALIGNER` env vars.

Do not commit `.venv/` — `./setup.sh` recreates it.
