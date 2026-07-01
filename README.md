# caption-lab

A standalone macOS app **and** CLI that reproduces PalmierPro's caption-correction pipeline end-to-end,
extracted into a fresh isolated repo so the real behavior can be tested outside the full app.

The pipeline **core** is copied faithfully from the main app (same prompts, same JSON schemas, same
retry/fallback chains, same 1:1 timing-writeback constraint, byte-faithful `WordCutPlanner`) — the whole
point is to exercise the actual pipeline, not a reimplementation. The only surgery is de-tangling the
pieces that hung off `EditorViewModel` into free functions, and reading the Gemini key from the
environment (or the app's key field) instead of the app Keychain. The SwiftUI GUI and the multi-clip
track model are built **on top of** that core; no external Swift package dependencies (system frameworks
only: SwiftUI, AVKit, AVFoundation, Speech, Accelerate).

## Pipeline (7 stages, run per clip)

```
clip.mov + GEMINI_API_KEY
  │
  ├─[1] MediaDescriber.describeVideoContentMap (GeminiClient.describeVideo)
  │        deep content map: [ContentSegment] (per-segment time range + visual + dialogue)
  ├─[2] Transcription (Apple SpeechTranscriber / SpeechAnalyzer)
  │        word-level ASR → TranscriptionResult (words with start/end, endpointed segments)
  ├─[3] CaptionPipeline.contentMapGlossaryTerms
  │        harvest proper nouns / domain terms the VLM heard → glossary
  ├─[4] TranscriptCorrector.correct(_, glossary:)
  │        Gemini TEXT correction 1:1 (homophones, brands, punctuation); corrected text written onto
  │        ORIGINAL word timings via applyCorrectedText (stutters/false-starts PRESERVED here)
  ├─[5] CaptionPipeline.retranscribeSuspectSpans
  │        spans where ASR disagrees with the content map are re-transcribed with Gemini audio,
  │        re-timed on syllable-nucleus energy peaks
  ├─[6] CutStutters.plan → WordCutPlanner.cutRanges
  │        decide which word indices are redundant disfluencies (LLM default, or heuristic), then
  │        ripple-cut them into FrameRanges (per clip, within that clip's own frame span)
  └─[7] TranscriptCorrector.applyCorrectedText
           TIMING-PRESERVATION CHECK: corrected-text writeback preserves every original ASR word's
           (start,end) exactly (PASS/FAIL)
```

## Multi-clip track model

The app is built around a **Track** = an ordered, reorderable list of **Clips**. Each `ClipModel` owns its
own video URL and its own full set of pipeline results (content map, ASR, glossary, correction diff,
retranscribe rows, cut ranges, timing PASS/FAIL) plus per-clip stage progress. Drop one or more videos to
append clips; add more anytime; drag to reorder; remove with the ✕. A single clip is just a track of one.

The 7-stage pipeline runs **per clip** (each video gets its own Gemini content map / ASR / correction /
retranscribe / stutter-cut), with clips processed **concurrently, capped at 2 at a time** so the Gemini
API isn't hammered. Stage 6 is per-clip: `WordCutPlanner` takes `clipStart`/`clipEnd`, so the ripple stays
within each clip.

### Timeline & joined playback

- The waveform + word-chip timeline spans the whole track on **one global RAW time axis** (clip A then
  clip B …), with dashed clip-boundary markers. Each clip's `AudioEnvelope` is concatenated for the track
  waveform; each clip's words and translucent-red cut regions render in that clip's segment. Clicking a
  word chip seeks playback to that word's **global** time; the playhead tracks playback.
- Playback is an `AVMutableComposition` of the ordered clips, so the track plays as one seekable timeline.
  A segmented toggle switches between **"Joined (raw)"** (full clips concatenated) and
  **"Joined + cuts"** (each clip inserted MINUS its stutter/filler ranges — the real tightened result). A
  composition↔raw-time map (`keptSegments`) converts between composition time and the raw global axis so
  the playhead and chip-seeking stay correct in both modes.
- Track totals show raw duration vs after-cuts duration and total seconds removed across all clips.

## Qwen (MLX) forced-aligner — A/B timing backend

Two ways to get per-word/char timings, compared side by side:

- **Apple ASR** (`SpeechTranscriber`): word/char timings from on-device recognition, with the corrected
  text written back onto those timings **1:1** — but only where correction kept the word/token count, so
  segments where correction changed count/boundaries keep the raw timing.
- **Qwen (MLX)** (`mlx-community/Qwen3-ForcedAligner-0.6B-8bit` via `mlx-audio`): a forced aligner that
  aligns the **FINAL corrected text directly to the audio** — its own clock, no Apple ASR, no 1:1-count
  writeback limit — so it times exactly the text the pipeline produced, including the segments Apple's
  path skips. Char-level Traditional Chinese timing confirmed (~1.2 s inference).

A **Timing backend** selector (Apple only / Qwen only / Both) drives the timeline: in **Both**, two
labeled clickable chip lanes ("Apple" / "Qwen") stack under the waveform so you can compare timing per
token. The Qwen path shells out to a Python sidecar (`aligner/qwen_align.py`) in the repo's `.venv`; if
the venv/script is missing the app shows a "run ./setup.sh" hint instead of failing. Enable it with:

```bash
./setup.sh
```

`setup.sh` creates `.venv` and installs `mlx-audio` (MLX only — no torch). The Qwen model (~hundreds of MB,
8-bit) **auto-downloads on the first alignment run** (needs network once, then cached). Peak RAM is
~**2.2 GB per alignment**, comfortable on an **M1 Pro / 16 GB**; the app serializes aligner runs so only one
model is resident at a time. Clips longer than ~5 minutes exceed the aligner's single-pass limit — the app
flags this and does **not** silently truncate. Override the Python/script paths with `CAPTIONLAB_PYTHON` /
`CAPTIONLAB_ALIGNER`.

The sidecar contract (stable): `qwen_align.py --audio <wav> --text <transcript> --language <lang>` prints
`[{"text","start","end"}, …]` (seconds) to stdout; progress/logs go to stderr.

## Build

Full Xcode toolchain required (CommandLineTools lacks pieces the toolchain needs).

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

## Run — GUI (primary)

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run CaptionLab [optional-media-path …]
```

Launches a dark, pro-video-tool window: a drop zone / "Add files…" picker, a reorderable track list with
per-clip stage dots, an AVKit video player with play + raw/cuts preview toggle, the global waveform/chip
timeline, and a right-hand column with a `GEMINI_API_KEY` field (prefilled from `$GEMINI_API_KEY` if set),
a glossary field, the retranscribe toggle, the stage-6 detector (LLM/heuristic) + aggressiveness pickers,
a **Run pipeline** button, a **Re-cut** button (re-runs only stage 6 + the timing check after changing
detector/aggressiveness), a PASS/FAIL timing badge, and per-clip result panels (cut summary, content map,
glossary, correction diff, retranscribe). Any media path passed as an argument is preloaded as a clip.

## Run — CLI (`--cli`)

The original scriptable pipeline is preserved behind `--cli` (single clip):

```bash
export GEMINI_API_KEY=…
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run CaptionLab --cli <path-to-media> [options]
```

| Option | Effect |
| --- | --- |
| `--glossary a,b` | Extra glossary terms, merged with harvested terms. |
| `--no-retranscribe` | Skip stage 5. |
| `--cut-heuristic` | Use the heuristic stutter/filler detector instead of the LLM (stage 6). |
| `--aggressiveness tight\|balanced\|loose` | Stage-6 keep-gap (default balanced). |
| `--model <m>` | Gemini model (default `gemini-flash-latest`). |
| `--dump-json <dir>` | Write per-stage JSON. |
| `--asr-json <file>` | Load a pre-exported `TranscriptionResult` instead of live ASR (see below). |
| `--language <lang>` | Content-map description language (default `Traditional Chinese`). |
| `--fps <n>` | Nominal fps for the stage-6 seconds↔frames conversion (default: read from the video, else 30). |

## Stage 6 — cut stutters / disfluencies

In the main app this decision is the LLM agent's (it reads the transcript and calls `remove_words`); this
harness replicates that. `TranscriptCorrector` deliberately **preserves** stutters/false-starts, so they
are still present after stage 4 and this is the stage that removes them. Two detectors:

- **LLM (default):** a Gemini call sends the numbered word list and asks for the indices of redundant
  stutter repeats / false starts / fillers to remove, **keeping the final clean instance of a repeated
  run** and never removing meaningful words. Schema-locked `{"cut":[int]}` (same pattern as
  `TranscriptCorrector`). Falls back to the heuristic if every attempt fails.
- **Heuristic (`--cut-heuristic`):** mark consecutive duplicate words (same normalized text) except the
  last in each run, plus any word in the app's byte-faithful `defaultFillers` set.

`WordCutPlanner` is byte-faithful and works in **frames** with `clipStart`/`clipEnd`; the ASR words are in
**seconds**. All unit conversion lives in the `CutStutters.plan` wrapper: seconds→frames for the planner
input (nominal fps = the video's `nominalFrameRate` if readable, else 30), and the resulting cut
frame-ranges→seconds for display + "seconds saved". `CutAggressiveness` (tight/balanced/loose) maps to the
planner's keep-gap.

## `GEMINI_API_KEY`

Required for stages 1, 3, 4, 5, and the LLM stage-6 detector — all call the direct Google Gemini API
(`generativelanguage.googleapis.com`). In the GUI, paste it into the key field (prefilled from the env if
set); the app injects it into the process environment before running so `GeminiClient` stays byte-faithful
(it still reads `$GEMINI_API_KEY`). The CLI reads it straight from the environment.

## Speech authorization caveat + `--asr-json` fallback

Stage 2 uses the modern `SpeechTranscriber` / `SpeechAnalyzer` API, which (per the main app's verified
note, kept in the extracted code) resolves locales and transcribes **without** an `SFSpeechRecognizer`
authorization gate — so ASR can work without a mic-usage prompt; the on-device model downloads on first
use. Running the GUI via `swift run` (no `.app` bundle / Info.plist) prints a benign AVKit runtime log
(`failed to demangle superclass … AVPlayerView`) and, if a given machine's speech XPC service refuses a
non-bundled client, stage 2 fails for that clip with a clear message. In that case the CLI's
`--asr-json <file>` loads a pre-exported `TranscriptionResult` so stages 3–7 run fully offline; `--dump-json`
writes `asr.json` in exactly that shape. If you ever need a mic/speech usage-description string, run from a
real `.app` bundle (`swift run` executables can't embed an Info.plist) — not required for file-based ASR.
