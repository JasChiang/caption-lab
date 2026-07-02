# CaptionLab

**English** | [繁體中文](README.zh-TW.md)

A macOS SwiftUI app **and** headless CLI for LLM-assisted caption correction — an experiment lab where
Apple's on-device speech recognition and Google Gemini cross-check each other to produce accurate,
karaoke-timed, edit-ready captions for real-world (fast, mumbled, jargon-heavy, code-switching) speech.

Grown out of a [PalmierPro](https://github.com/palmier-io/palmier-pro) fork: the upstream app uses Apple
`SpeechTranscriber` only; everything LLM-side here (content map, correction, re-listening, disfluency
marking) is this lab's addition, developed in isolation so the pipeline can be measured, A/B-tested, and
ported back. No external Swift package dependencies — system frameworks only (SwiftUI, AVFoundation,
Speech, SoundAnalysis, Accelerate).

## Architecture — perception / judgment / mechanics

```
PERCEPTION   Apple SpeechTranscriber ──── per-word timings (the only clock)
(two ears)   Gemini content map ────────── independent 2nd transcription + speakers + terms
                                           (never shown the ASR text — no anchoring)
                      │
JUDGMENT     ONE Gemini text call: corrects mishearings (homophones, code-switching),
(one pass)   adds punctuation, and emits ALL marks in the same judgment —
             ¦ caption line breaks · ⟦term⟧ never-split terms · ⟨disfluency⟩ words to cut
                      │
MECHANICS    deterministic, no AI: 1:1 timing writeback (LCS-aligned), energy-peak
(pure fn)    re-timing for recovered syllables, ripple-cut planning, valley-snapped
(portable)   cut boundaries, caption chunking. Ports to any NLE.
```

Two semantic calls per clip, total (plus optional per-span re-listening). One judgment pass means the
caption text and the cut list can never disagree.

### Pipeline stages

| # | Stage | Engine |
|---|-------|--------|
| 1 | Content map — watch the whole clip: verbatim dialogue blocks, speaker labels, summary, harvested terms | Gemini (video) |
| 2 | ASR with pre-conditioning (normalize/compress; experimental slow-down for fast speech) | Apple, on-device |
| 3 | Glossary — map-harvested terms merged with a manual list (no extra call) | — |
| 4 | Correction — the one judgment pass (text + punctuation + ¦ + ⟦⟧ + ⟨⟩), count-locked to preserve timing | Gemini (text) |
| 5 | Re-listen suspect spans where correction still disagrees with the map; splice + energy-peak re-timing | Gemini (audio, opt-in) |
| 6 | Cut disfluencies — executes the ⟨⟩ marks mechanically; heuristic fallback offline | — |
| 7 | Timing self-check — verifies 1:1 word-timing preservation (drift must be 0) | — |

### Features

- **Audio quality report** per clip: clipping %, SNR estimate, background-music spans (Apple SoundAnalysis).
- **Speaker-aware caption breaks**: the map's speaker labels ride into correction, so a host→guest handoff
  splits the caption even with zero pause — and cross-speaker echoes are never mistaken for stutters.
- **Manual caption editor**: click a line to seek, edit in place (Enter splits a line), merge with next;
  unchanged text keeps its timing, changed runs re-time on syllable energy peaks.
- **Gemini usage/cost dashboard**: per-model token counts and cost estimates at official rates, per session.
- **Qwen (MLX) forced-aligner A/B lane** for comparing timing backends (optional, `./setup.sh`).
- **Annotated-transcript JSON** (`--dump-json`): segments carry text/start/end/captionBreaks/cutUnits —
  a portable interchange document any NLE exporter (SRT, FCPXML, ripple cut list) can consume.
- `--cli --audio-check <media>`: on-device diagnostics (quality, conditioning, ASR A/B) with no API key.

### Requirements

- Apple Silicon Mac, macOS 26+, **full Xcode** (SwiftUI macros need more than Command Line Tools)
- `GEMINI_API_KEY` for the LLM stages (paste into the GUI field, or put it in `.env` — see `run.sh`)

### Build & run

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
./run.sh                       # GUI (sources .env, launches the app)
swift run CaptionLab --cli <media> [--model gemini-pro-latest] [--dump-json out/]
swift run CaptionLab --cli --audio-check <media>    # no key needed
```

### Field notes (see DEVLOG.md for the full lab log)

- **Independence is the whole trick**: the content map never sees the ASR text, so its "second opinion" can
  catch same-sounding errors that look plausible alone. Merging the two calls would save ~$0.003 and
  destroy the mechanism.
- **Count-lock**: correction may swap words but never add/remove syllables — that's what keeps Apple's
  per-word clock intact (verified drift 0 across all test clips). Dropped syllables are the re-listen
  stage's job instead.
- **Negative results we paid for so you don't have to**: time-stretching fast speech before ASR *swaps*
  errors instead of reducing them; a forced aligner (Qwen) produced worse timing than Apple's ASR
  boundaries; per-word-list LLM cut decisions mis-cut CJK reduplications (常常) until cut marking moved
  into the sentence-level judgment pass.

Test clips are local media (never committed) referenced by neutral aliases in the dev log.

### Credits & provenance

- **Direction**: [@JasChiang](https://github.com/JasChiang) provided the architectural ideas and design
  decisions (the perception/judgment/mechanics split, the cross-checking approach, what to build and what
  to reject) — steering, testing on real clips, and calling out the over-fitting.
- **Implementation**: essentially all of the code was written by **Claude Code** (Anthropic) working under
  that direction — see the co-author trailers throughout the commit history, including the bugs it wrote
  and then had to find.
- **Apple `SpeechTranscriber` as the ASR front-end comes from [PalmierPro](https://github.com/palmier-io/palmier-pro)**
  (the upstream project, which uses Apple ASR only); the LLM layers were added in this lab.

### License

GPL-3.0, same as upstream — see `LICENSE` and `NOTICE` for provenance.
