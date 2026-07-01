# CaptionLab — Dev Log & Handoff

Running notes so work can continue on another machine. Newest session on top.

---

## Session 2026-07-01 — beta build fix, cut precision, speaker diarization, map-referenced correction

Branch: `caption-pipeline-improvements` (off `main`).

### Fresh-machine setup (nothing here is committed as secrets)
1. **Xcode**: this repo needs the toolchain that matches the SDK on the machine. On the dev box that was
   **Xcode 27.0 Beta 2** (macOS 27 / SDK `MacOSX27.0.sdk`). Full Xcode is required — Command Line Tools alone
   lacks the SwiftUI macro plugin (`SwiftUIMacros`) and the build fails at `@State`.
   ```bash
   brew install xcodes
   xcodes install "27.0 Beta 2"            # Apple ID login, ~7–12 GB
   sudo xcodes select "27.0 Beta 2"
   sudo xcodebuild -license accept
   ```
   (If the machine's SDK differs, install the matching Xcode instead — check `xcrun --show-sdk-version`.)
2. **Qwen aligner venv** (optional, only for the A/B Qwen lane): `./setup.sh` → builds `.venv`, installs
   `mlx-audio`. Model auto-downloads on first Qwen run (~1.2 GB, cached).
3. **Gemini key**: create `.env` (gitignored) with `GEMINI_API_KEY=…`, then launch with `./run.sh`
   (it sources `.env` before `swift run` — the app itself does NOT read `.env`). Or paste the key into the
   GUI field, or `export GEMINI_API_KEY=…`.
4. **Build / run**: `swift build`; GUI `./run.sh [media]`; headless `swift run CaptionLab --cli <media>
   [--dump-json dir] [--model gemini-pro-latest] [--no-retranscribe] [--cut-heuristic]`.

### What changed this session (see git log on this branch)
1. **Xcode-27-beta compatibility**
   - `ContentView.swift`: SwiftUI `VideoPlayer` → custom `AVPlayerViewRepresentable`. SwiftUI's `VideoPlayer`
     crashes at launch on the beta runtime (fails to demangle the `AVPlayerView` superclass → SIGABRT).
   - `AppEntry.swift`: added `AppDelegate` setting `.regular` activation policy + `activate` — a bare
     `swift run` executable otherwise launches as a background "Non UI" process (no Dock icon, window hidden).
2. **Cut precision — energy-valley snapping** (`CutStutters.swift`, wired via `url` param)
   - Recognizer word boundaries sit ON the syllable, so a frame-snapped cut slices mid-syllable and leaves an
     audible fragment (the "去去去 cut but the first 去 still sounds" bug). `snapToValleys()` nudges each cut
     boundary to the quietest instant within ±70 ms. Verified: boundaries moved into valleys 4–14× quieter.
3. **Speaker diarization (route 1 — no extra model)**
   - `ContentSegment.speaker` field; content-map prompt/parser now emit `<speaker> | <visual> | <dialogue>`.
     Gemini already distinguishes speakers when it writes the map; we just capture it as structured data.
   - Shown in the GUI content panel (`ResultsPanels.swift`) and CLI ("Speakers detected: 主持人, 來賓").
4. **Caption correctness (the big one — `TranscriptCorrector.swift`)**
   - **Granular LCS backfill** (`applyCorrectedText` + `alignedPositionalSwaps`): the old writeback skipped a
     WHOLE segment when its corrected unit count drifted by even 1 vs the ASR word count — which threw away
     easy same-position fixes like 整年檢壓→正念減壓. Now aligns ASR↔corrected units by LCS and swaps only
     unambiguous positions (matched anchors + equal-length substitution runs); unequal runs are left as raw.
   - **Content-map REFERENCE fed into correction**: each ASR line now carries the overlapping content-map
     dialogue as a REFERENCE. Correction prefers it for soundalike errors with no textual cue (一樣→遺憾),
     while keeping stutters (the map drops them — the prompt forbids collapsing repeats). This is the
     "Apple gives timing, Gemini gives the correct words, backfill" architecture the user asked for.

### Key findings / decisions
- **Qwen forced-aligner timing is unreliable** on real clips: ~10% zero-width tokens + many gaps vs Apple's
  clean contiguous boundaries. So cuts are refined on ASR boundaries (energy-valley), NOT driven by Qwen.
  **Qwen is kept but stays opt-in** (default `alignerMode = .apple`); not removed — it's the A/B lab's control.
- **We don't need Qwen for correctness**: Apple timing + Gemini-corrected text + granular backfill covers the
  common case; genuine syllable insertions are re-timed by `placeOnEnergyPeaks` (retranscribe stage).
- **flash vs pro**: on clean-ish interview content `gemini-flash-latest` matches `gemini-pro-latest`
  (identical correction, near-identical map) at ~10× less cost. Escalate to pro only for hard clips
  (dense jargon, overlapping speakers, noisy audio). Switch via `--model` / GUI model field.
- **Map-referenced correction generalizes** (not overfit): tuned on 受訪者A (fixed 1 soundalike), it fixed a
  whole run of medical terms on 講者B unprompted (趕細胞→幹細胞, 粒腺體→粒線體, 吩泌→分泌, 得竹→得主, 某大學→某大學),
  stutters preserved, timing drift 0. Prompt example was genericised (反應/反映) to avoid anchoring.

### Open / next steps
- **Long-term overfit watch**: the "prefer the map" rule COULD trade an ASR-correct word for a map-wrong one.
  2 clips showed only improvements, but validate on more, varied clips; consider logging map-swap accuracy.
- **Manual-edit re-timing** (user idea): when a human fixes text both ASR and map missed, re-time that span
  with the existing `placeOnEnergyPeaks` (1 CJK char ≈ 1 energy peak). Infra already exists in the retranscribe
  path; would need a GUI "edit caption line → re-time span" hook.
- **Export cut video** (deferred — preview via "Joined + cuts" is enough for now): ffmpeg `select/aselect +
  concat` to render the ripple cut. Also considered: `silencedetect` (sturdier than our RMS valley),
  `afftdn`/`loudnorm` denoise+normalize before ASR to reduce recognition errors at the source.

### Test clips used
`~/Desktop/pp-test/受訪者A_訪談測試.mp4` (2-speaker interview, disfluent),
`~/Desktop/pp-test/講者B_演講測試.mp4` (domain talk, heavy jargon). Both: timing drift 0, PASS.
