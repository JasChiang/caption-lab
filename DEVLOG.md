# CaptionLab — Dev Log & Handoff

Running notes so work can continue on another machine. Newest session on top.

---

## Session 2026-07-04 — zh-TW recognition / two-tier disfluency / offline "second ear" (all GENERAL)

Branch: `claude/subtitle-recognition-improvements-frivjs` (off `main`). Authored on Linux — **UNBUILT, verify
on the Mac** (M4 Pro / 64 GB per user). Goal from the user: improve recognition, stutter/filler cutting, and
speaker-count detection, *especially* for Taiwan Traditional Chinese — WITHOUT over-fitting the workflow to
one language family (explicit user pushback mid-session: a hardcoded zh-TW model "won't let this workflow
generalise"). So every change here is a GENERAL mechanism; the zh-TW specifics are examples or scoped knobs.

### 1. Two-tier disfluency marking (口吃 / 贅詞) — general mechanism, TW fillers as examples
- The corrector's ONE judgment pass now emits **two** cut tiers instead of one (`TranscriptCorrector` system
  prompt): **⟨ ⟩ tier-1** = always-removable junk (stutter repeats, false starts, hesitation 嗯/呃/啊/um/uh),
  and **⟪ ⟫ tier-2** = STYLISTIC discourse-marker padding — a word used as a verbal tic, not for its literal
  meaning. TW examples in the prompt (那個/這個 as a stall, 就是/就是說 as padding, 然後 as a run-on tic, 對/對啊
  as a filler beat, 欸/齁/蛤) with matched NEGATIVE examples (然後我們就走了 = real sequence, kept) so the LLM
  generalises rather than pattern-matches a word list. The tier concept is language-agnostic (prompt also names
  English "like/you know/I mean").
- New `TranscriptionSegment.stylisticCutUnits` (Codable, defaults `[]` → old dumps still decode). Parsed by
  new `extractStylisticMarks` (⟪⟫ = U+27EA/U+27EB, same index space as ⟨⟩ — verified the code points in the
  prompt match the parser). `CutStutters.indicesFromMarks(result:includeStylistic:)` folds tier-2 in ONLY when
  the caller asks. **Aggressiveness now gates the tier**: tight/balanced cut tier-1 only; **loose ALSO cuts
  tier-2** — so a conservative edit never removes a 那個/就是 that might be doing real work. Wired in CLIRunner,
  PipelineViewModel (run + rerunCut), and the manual editor shifts/drops ⟪⟫ marks exactly like ⟨⟩.
- Design note: this deliberately did NOT expand the `defaultFillers` HEURISTIC list (那個/就是/然後 are too
  often meaningful for a context-free list — the same reason 啊/唉 were excluded). The judgment happens in the
  sentence-level LLM pass where context exists; the heuristic stays the minimal offline fallback.

### 2. Offline local-ASR "second ear" (recognition) — model is a KNOB, not a hardcode
- This is the reframed answer to the over-fitting concern. Instead of bolting in a Taiwan-tuned ASR model, the
  stage-5 re-listen (retranscribe suspect spans) gained a pluggable backend: `RefineBackend { gemini,
  localASR }`. `.gemini` is the untouched cloud default; `.localASR` runs a **general** offline Whisper via a
  new sidecar (`asr/local_asr.py`, `LocalASR.swift`) that mirrors the Qwen sidecar plumbing (shared `.venv`,
  serial subprocess). The stage's map-agreement gate + energy-peak re-timing are IDENTICAL either way — only
  the listener swaps.
- **The model is chosen by `$CAPTIONLAB_ASR_MODEL`**, defaulting to `mlx-community/whisper-large-v3-mlx`
  (general multilingual, works out of the box). A Taiwan user can point it at a locale-tuned checkpoint (e.g.
  an MLX-converted Breeze-ASR-25 for TW Mandarin + code-switching) — opt-in, no pipeline dependency on any
  language. Offline = free, so it's also a no-API path for the whole re-listen stage.
- Wiring: CLI `--refine-local` (+ availability print + Gemini fallback if not set up); GUI segmented picker
  "Re-listen backend" in ControlsPanel + `vm.refineBackend`; `setup.sh --asr` installs mlx-whisper (Qwen path
  unchanged; `--all` does both). ffmpeg note added (mlx-whisper decodes via ffmpeg).

### 3. Taiwanese Hokkien (台語) + speaker-count (recognition / 說話人數) — scoped prompt notes
- `TranscriptCorrector`: a `taiwaneseRule` telling the corrector to render clearly-Hokkien spans in standard
  Han characters (敢有/按呢/逐家…) instead of forcing Mandarin homophones, and to keep raw chars rather than
  invent a homophone when unsure. **Gated to zh/unknown audio** (`result.language`) so a non-Chinese clip
  never sees it — same "general corrector + scoped note" shape as codeSwitchRule.
- `MediaDescriber` content-map prompt: same Hokkien rule for `<dialogue>` (the map is the reference correction
  leans on), and a hardened `<speaker>` rule — one label per DISTINCT voice, never merge/split, label
  off-screen/voice-over speakers — so the distinct-speaker COUNT can be read straight off the map. CLI now
  prints "Speakers detected (N): …".

### Files touched
Models.swift, TranscriptCorrector.swift, CutStutters.swift, CaptionPipeline.swift, CLIRunner.swift,
PipelineViewModel.swift, ControlsPanel.swift, CaptionEditor.swift, MediaDescriber.swift; new LocalASR.swift +
asr/local_asr.py; setup.sh. No new Swift package deps.

### Verify on the Mac (checklist)
1. `swift build` (green?) — new field + two-tier parse + LocalASR are pure Swift; watch the memberwise-init
   call sites (all pass labels).
2. Two-tier cut: run a disfluent TW clip at `--aggressiveness balanced` vs `loose`. Balanced should cut only
   stutters/fillers; loose should ADDITIONALLY drop padding 那個/就是/然後 — and the CLI "stylistic padding
   (⟪⟫)" line should report the count and whether it was cut. Confirm a REAL 然後/那個 (然後我們就走了) is NOT
   marked ⟪⟫.
3. 台語 clip (財經節目E had a 台語 idiom): check a Hokkien span comes out in Han characters, not Mandarin mush.
4. `./setup.sh --asr`, then `--refine-local` on a garbled clip: confirm the offline sidecar re-transcribes a
   suspect span and the map-agreement gate still guards acceptance. Try `CAPTIONLAB_ASR_MODEL=…` override.
   (Breeze-ASR-25 needs MLX-format weights — the default whisper-large-v3-mlx is the out-of-box control.)
5. Speaker count: multi-speaker interview (受訪者A) → "Speakers detected (2)"; confirm no split/merge.

### Deferred (documented, NOT started — the honest next tranche)
- **contextualStrings wiring (ASR gap #1)**: DEVLOG session (g) confirmed the symbols exist via SDK grep, but
  the exact `AnalysisContext` / `setContext` shape is unverified and a wrong guess would wedge the WHOLE build
  — left for the Mac where the compiler checks it interactively. Plumb the harvested glossary into
  `Transcription.transcribe` then set it on the analyzer.
- **Acoustic speaker diarization**: today speakers are labels-only from Gemini; no acoustic verification. Next
  isolated sidecar (same shape as Qwen/LocalASR): sherpa-onnx diarization → cross-check the map's labels
  (acoustic gives turn times + count, Gemini gives identity) and feed authoritative speaker-change ¦ breaks.
- **Eval harness** (`--score`: CER/MER, cut precision-recall, DER) so each of the above becomes a number, not
  a vibe.

---

## Session 2026-07-02 (i) — ONE semantic pass: cut decisions fold into the corrector (de-overfit)

User pushback (correct): the 常常 reduplication whitelist was whack-a-mole, and stage 6's LLM was the only
semantic judgment that saw NO sentence context (a bare one-char-per-line word list). Restructured to the
general architecture — perception / judgment / mechanics:

- **Judgment happens ONCE** (stage 4): the corrector now also wraps removable disfluencies in ⟨ ⟩ (it already
  had to identify them to preserve them). New `TranscriptionSegment.cutUnits` carries the marks alongside
  `captionBreaks` — corrections, breaks, atomic terms and cuts are one consistent judgment; the cut list can
  never disagree with the caption text.
- **Stage 6 is now pure mechanics**: `llmCutIndices` DELETED (one fewer Gemini call per clip); `Detector.llm`
  → `.marks` (`indicesFromMarks` maps segment cutUnits → global word indices positionally); heuristic remains
  the offline/no-marks fallback (`fellBack` when marks were requested but correction failed). The reduplication
  whitelist prompt died with llmCutIndices; the heuristic's CJK-pair rule stays (a linguistic fact, not a patch:
  real CJK stutters run 3+, pairs are reduplications).
- **Annotation document**: `--dump-json`'s corrected.json/final.json now IS the portable annotated transcript
  (segments carry text/start/end/captionBreaks/cutUnits + words) — the interchange format an NLE (PalmierPro)
  consumes; exporters (SRT/FCPXML/remove_words) are pure functions of it.
- Manual edits preserve/shift cutUnits like breaks (marks inside an edited span are dropped as stale).
- Retranscribed spans get fresh text with empty cutUnits (old marks would be stale — correct behavior).

VERIFIED (2026-07-02, user): marks mode works on real clips — stutters cut, 常常-class reduplications kept,
AND speaker-change ¦ breaks split host/guest handoffs while cross-speaker echoes survive ⟨⟩ marking.
Original checklist: rerun a disfluent clip (受訪者A/講者B) — CUT SUMMARY should show mode "marks", stutters cut,
常常-class words kept; 朗讀者C should show few/no cuts. GUI picker now "Corrector marks (default) / Heuristic".

---

## Session 2026-07-02 (h) — manual caption editing + Gemini cost dashboard

1. **Manual caption editing** (`CaptionEditor.swift` + CAPTION LINES card in ResultsPanels). Edit a line in a
   multi-line field — **Enter splits into separate caption lines** (PalmierPro convention; ¦/| also work) —
   or merge with the next line (within a segment: drop the break; across segments: merge the segments).
   Edits mutate `clip.afterRetranscribe` (the artifact captions render from), text that still matches keeps
   its word timing (LCS), changed runs re-time on energy peaks via `applyCorrectedText`. A `[totalUnits]`
   sentinel break keeps captionStops' LLM path authoritative when a merge removes the last interior break
   (else the punctuation fallback would re-split). Re-running the pipeline overwrites manual edits.
   Chunking refactored into `captionChunks(for:)` — single source for overlay cache + editor.
   NOT yet done: PalmierPro's Alt+Enter soft wrap WITHIN one caption (needs an intra-line break in the data
   model; overlay auto-wraps for now).
2. **Gemini usage/cost dashboard** (`GeminiUsage.swift`, UsagePanel between Controls and Results). Every
   generateContent call records model + prompt/output tokens + audio-video share (promptTokensDetails) into
   a session ledger; panel shows per-model calls/in/out/cost + total. Rates hardcoded from
   ai.google.dev/gemini-api/docs/pricing (2026-07, paid tier): pro $2/$12, flash $1.50/$9, lite $0.10
   (AV-in $0.30)/$0.40 — pro >200k surcharge not modeled. CLI records don't materialize (main thread blocked
   on the semaphore) — GUI feature.
3. **Bugfix — wrong-window energy peaks**: `TranscriptCorrector.correct` passes a FULL-clip envelope but
   `placeOnEnergyPeaks` treats sample 0 as span start, so inserted-run re-timing picked peaks from the wrong
   window. Added `AudioEnvelope.slice(_:)` and sliced in `rebuildSegment` (manual edits + correction both).
4. Earlier today (see commits): ¦ breaks made authoritative (16-cap only on the punctuation fallback),
   orphan-tail fix (min 2-unit tail), GUI model default → gemini-pro-latest, slow-fast default OFF,
   retranscribe re-listen now uses the pipeline model (was stuck on flash-lite).

---

## Session 2026-07-02 (g) — first Mac build + runtime verification

Machine: local Mac, **Xcode-beta 26.4** (`/Applications/Xcode-beta.app`; CLT-only select fails — full Xcode
required). Build: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build`. Now GREEN.

### Build fixes (were broken from Linux authoring)
- `SwiftUI.TimelineView` had to be qualified — this module defines its own `struct TimelineView` (waveform),
  which shadowed it in the new running-status line. Symptom was the bogus "type 'PipelineViewModel' has no
  member 'periodic'".
- AVAudioEngine offline-render `switch` needed an explicit `.error` case (throws → conditioning falls back).

### New diagnostic: `--cli --audio-check <media>` (no Gemini key needed)
Runs SoundClassifier + AudioQuality + AudioConditioner, then an on-device ASR A/B (conditioning OFF vs ON)
printing word count, first.start, last.end, overshoot-past-duration. Runs before the key gate.

### Verification results (5 test clips)
- **Bug #1 (SoundClassifier fed a video container) — NOT a bug.** `SNAudioFileAnalyzer` opens `.mp4` fine:
  評測頻道D music 52% (6 spans, warned), 財經節目E 0%, 朗讀者C 15%. Music detection works.
- **Bug #2 (time-pitch priming latency) — NOT present.** On a slowed clip (講者B @0.86×): first.start=0.00
  (no leading offset), last.end 55.77 < 55.82 dur (no overshoot). Mapping is clean.
- **NEW bug FOUND + FIXED: `syllableRate` overcounted ~5×.** Raw 10 ms envelope local-maxima read every
  clip at 25–30 syl/s, so ALL clips tripped the fast threshold and slowed to 0.60× (adaptivity dead).
  Fix: smooth envelope ~50 ms + enforce ≥140 ms inter-peak spacing. Now realistic: 朗讀者C 5.9 / 評測頻道D 6.1 /
  財經節目E 5.7 → no slow; 受訪者A 7.4 / 講者B 7.5 → mild slow (0.86–0.88×).
- **Conditioning A/B proves the point:** 講者B (unclear speech) 261→**265 words** with conditioning ON;
  朗讀者C (clean) 91→91 **identical** (normalize doesn't disturb clean audio). Net win where needed, no
  regression where not.
- Bug #3 (clipping measured post-resample) — unverified (no clipped test clip; all read 0.00–0.05%). Left as-is.
- Bug #5 (zero-width-word cut) — pre-existing edge case, not hit here.

### CONFIRMED via SDK grep: contextual biasing IS available on this SDK
`Speech.AnalysisContext` has `contextualStrings: [ContextualStringsTag: [String]]` with `.general`;
`SpeechAnalyzer` exposes `var context` / `setContext(_:)` and an `analysisContext:` init param. So gap #1
(auto-feed the content-map-harvested terms as contextual bias, zero manual) is now WIREABLE. Caveat unchanged:
the module may be `DictationTranscriber` that honors it vs `SpeechTranscriber` — setting it is free either way
(opportunistic upside). NOT yet wired — needs the term harvest moved before ASR + threading into Transcription.

### Still open
- Wire contextualStrings (gap #1) — decision pending (free to set, uncertain if SpeechTranscriber honors it).
- Unit-test target (needs lib/exe split) — still deferred; now that build works on the Mac it's safe to do.
- CLAUDE.md says "macOS 26"; this Mac's newest is Xcode 26.4 (no 27 installed here) — leave as-is, accurate.

---

## Session 2026-07-01 (f) — closing the functional gaps from (e)

Branch: `claude/fast-speech-transcription-7zyzzn`. Implemented the ranked functional gaps. Still UNBUILT
(Linux); verify on the Mac.

1. **Fast-speech segmentation — breath-snapped forced breaks** (`PipelineViewModel.captionStops/captionLines`).
   When a caption chunk exceeds `maxUnits` and has no comma to break on, it used to blind-cut at `s+maxUnits`.
   Now it picks the biggest inter-word pause (>40 ms) in the window — a real breath — so forced breaks land at
   micro-pauses instead of mid-phrase. Additive: falls back to the old hard cut when no gap data / no pause.
   Gaps are computed from ASR word timings (no envelope needed), positional unit≈word mapping (same
   approximation the chunk loop already uses).
2. **Conditioning visibility** — `TranscriptionResult.conditionReport` now carries the AudioConditioner report
   (non-Codable, transient, carried through `offsetting`). Surfaced in the GUI AUDIO QUALITY card
   ("conditioned: normalize +9dB · 7.2 syl/s · slow 0.85×") and the CLI stage-2 line. Plus CLI
   `--ab-conditioning`: re-runs ASR with conditioning OFF and prints both transcripts to compare (opt-in,
   doubles ASR time).
3. **Progress legibility** (session (a)'s flagged priority) — `PipelineStage` gained `startedAt` + `detail`;
   `ClipModel.mark` stamps the start time, `detail(_:_:)` sets a sub-status. GUI shows a live
   `TimelineView(.periodic)` status line under the clip header ("Content map · Gemini watching… · 0:23") so
   the slow content-map/retranscribe stages never look hung.
4. **Content-map timestamp slop** — the whole-second, model-estimated map timestamps now get ±1.0 s slop in
   both overlap checks (`CaptionPipeline.mapDialogue`, `TranscriptCorrector.mapRef`) so a reference just
   outside an exact window is still matched (charOverlap gating downstream absorbs any extra dialogue pulled
   in). Cuts false negatives in suspect-span detection.

### Deferred (needs the compiler, do on the Mac)
- **Unit tests** — the pure functions (`compress`/`normalizePeak`/`gate`/`syllableRate`/`stretchRate`,
  `CaptionBuilder.units`, `charOverlap`, `alignBlocks`) are ideal XCTest targets, but a test target can't
  `@testable import` an executable target. The refactor: add a library target `CaptionLabKit` with all the
  logic, leave `CaptionLab` as a thin executable (`main`/`@main` only) depending on it, then a `.testTarget`
  on the Kit. Doing that package split blind risks a broken `@main`/duplicate-main build, so it's left for the
  Mac where the compiler catches it immediately. NOT started to avoid breaking the build.
- CLAUDE.md still says "macOS 26" → bump to 27 after the first successful build confirms the SDK.

### Verify on the Mac (carried from (e), still open)
The 5 likely bugs from session (e) are unchanged — SoundClassifier fed a video container, time-pitch priming
latency, post-resample clipping detection, exact-Double timing equality, zero-width-word cut blindness.

---

## Session 2026-07-01 (e) — gap audit of sessions b–d (pre-Mac-build review)

Branch: `claude/fast-speech-transcription-7zyzzn`. Re-reviewed the new (still unbuilt) code adversarially +
scanned the rest of the pipeline. Ranked list of what's NOT solid yet.

### Likely bugs in the new code (verify on the Mac, in this order)
1. **SoundClassifier is fed the VIDEO file** (`AudioQuality.analyze(url:)` gets clip.url / mediaURL).
   `SNAudioFileAnalyzer` may not open a video container (docs say "audio file"; likely AVAudioFile-backed).
   If it throws, music detection silently returns nil forever. Fix if so: extract the audio track first
   (reuse `Transcription.extractAudioTrack` / a temp WAV) and feed THAT to the classifier.
2. **AVAudioUnitTimePitch priming latency**: the offline render in `AudioConditioner.timeStretch` may emit
   ~0.1 s of priming before real audio, shifting ALL word timings on stretched clips by a constant offset.
   Verify: on a slowed clip, click a word chip and check the audio actually says that word. Fix if so: trim
   `pitch.latency` (or measure lead-in silence) off the front before writing.
3. **Clipping detection measured post-resample**: `readMonoFloats` decodes at 16 kHz mono — resample
   filtering + stereo→mono averaging can pull clipped peaks below the 0.98 threshold → under-detection.
   Fix if so: measure clipping on the native-rate, per-channel samples instead.
4. **Exact-Double-equality timing matches** now carry scaled values (`start * timeScale`):
   `CaptionPipeline.swift` segment match (`$0.start == s.seg.start …`) and the stage-7 drift checks
   (`a.start != b.start`) require the product to flow through bit-identical. Today it does (single multiply
   at decode); any future re-derivation elsewhere will silently break span writeback / show fake FAIL.
   Consider switching those to epsilon compares while touching the area.
5. **Zero-width-word cut blindness** (pre-existing, worsened slightly by scaling): a timed word whose
   start/end round to the same frame is dropped by WordCutPlanner's `endFrame > startFrame` filter and can
   never be cut. Low fps + scaled timings widen the window.

### Functional gaps (ranked by value)
- **Fast-speech SEGMENTATION still untouched** — the ② layer from the original analysis. Run-on segments
  (no pauses when talking fast) go into correction as one huge line; the planned dual-track split (energy
  valleys as candidates + LLM ¦ choosing among them) is still backlog. This is the biggest remaining lever
  for fast speech.
- **Conditioning is invisible in the GUI** — the report (syl/s, chosen stretch, gain) only goes to stderr.
  Surface per-clip "conditioned: slow 0.85× · +9 dB" in the CLIP panel; also add the promised A/B tool
  (same clip, conditioning on vs off, diff the transcripts) so tuning has evidence.
- **Progress legibility** — flagged "user's priority" in session (a), still not done (stages show only
  binary running/done; the 30 s–2 min content-map stage looks hung).
- **Content-map timestamps are whole-second, model-estimated** — retranscribe's suspect-window overlap
  (charOverlap over a time window) inherits ±1 s+ slop; a tighter map (or fuzzy window growth) would cut
  false negatives on suspect-span detection.
- **Zero tests** — the DSP passes (`compress`, `normalizePeak`, `gate`, `syllableRate`, `stretchRate`,
  `placeOnEnergyPeaks`, `units`) are pure functions over [Float]/String, ideal for a first XCTest target on
  the Mac; would have caught the log10f issue class at build time.
- **Triple full-file read on clip add** (floats + envelope + classifier) — fine for a lab tool, consolidate
  into one decode if it ever feels slow.
- Docs: CLAUDE.md still says "macOS 26" — machine is on macOS 27 beta (Xcode 27); update after the build.

### Verified OK during this audit
Theme members all exist; WordCutPlanner/RippleEngine are all-Int frame math (scaled timings safe);
TimelineView clamps zero-width chips to 14 px (no invisible words); CutStutters' valley snapping is
grid-based, no exact-equality on times.

Branch: `claude/fast-speech-transcription-7zyzzn`. Researched (Apple docs / WWDC25) which Apple tools help
the fast/quiet/accuracy goals. Findings + one shippable win.

### Findings (verified against official docs / WWDC25 session 277)
- **Source-side biasing (contextualStrings / custom vocab)** — NOT usable here. In the new Speech API,
  `SpeechTranscriber` (what we use) does NOT support `AnalysisContext.contextualStrings`; only
  `DictationTranscriber` does, and it's dictation-oriented (not built for long recorded clips). Custom
  vocabulary is unsupported in the new API entirely. Reverting to `SFSpeechRecognizer` for `contextualStrings`
  is the only path — not worth it: our auto-harvested glossary + content-map REFERENCE already inject those
  terms into correction with zero manual work.
- **Voice-processing denoise** (`setVoiceProcessingEnabled`, AEC/NS/AGC) — bound to a live I/O node; offline
  manual-rendering has no I/O node, so it can't clean a FILE offline. `AUDynamicsProcessor` / `AVAudioUnitEQ`
  are offline-usable but would only replace our working hand-rolled DSP laterally → skipped.
- **SFVoiceAnalytics** (voicing/pitch/jitter/shimmer) — old-API only (`SFTranscriptionSegment.voiceAnalytics`);
  the new `SpeechAnalyzer` doesn't expose it. Not worth reverting for marginal segmentation gain. (If breath-
  aware segmentation is wanted, do it from our existing energy envelope — no Apple API needed.)
- **SoundAnalysis** — YES. `SNAudioFileAnalyzer` + `SNClassifySoundRequest(.version1)` runs Apple's built-in
  ~300-category model OFFLINE; labels include `music`/`speech`/`singing`. This is the one item Apple actually
  ships a model for.

### New: `SoundClassifier.swift` — real music detection (upgrades the SNR heuristic)
Runs the built-in classifier over the file, flags windows where `music`/`singing` ≥ 0.5 confidence, merges
them into spans, returns `musicFraction` + `ranges`. Folded into `AudioQuality`: replaces the vague "noisy or
music bed" SNR warning with a precise "Background music in X% of the clip (0:MM–0:MM…)". Detection only — it
separates music from noise, it does NOT separate music from speech (that still needs a separation model).
Surfaced in the GUI AUDIO QUALITY card (music pill) and CLI stage-2 line.

### Open / next steps
- **Untested — needs a Mac build.** Test music detection with `jargon_評測頻道D` (produced tech review, likely has
  intro/background music → expect music% > 0) vs `clean_朗讀者C` (poetry, expect ~0% as a control). Tune
  `musicThreshold` (0.5) / `musicWarnFraction` (15%).
- SoundAnalysis adds a 3rd audio read at clip-add (floats + envelope + classifier); fine for a lab tool.

---

## Session 2026-07-01 (c) — signal-quality warnings + code-switching

Branch: `claude/fast-speech-transcription-7zyzzn`.

Follow-up covering the remaining speech pathologies. The honest split: what a system-frameworks-only build
can genuinely FIX, what it can only reliably DETECT, and what needs an ML model we don't ship.

### New: `AudioQuality.swift` — always-on raw-source analysis (detect, don't fake)
Runs on the RAW audio (before conditioning) and surfaces warnings; fixes nothing it can't honestly fix.
- **Clipping / 爆音** — counts samples pinned near full scale (|x| ≥ 0.98). Clipped audio is irreversibly
  distorted, so we WARN (>0.2%) rather than pretend to repair it.
- **Low SNR / noisy or music bed** — RMS-envelope percentile ratio (speech p90 / floor p10). Below ~12 dB →
  warn. True source separation needs a trained model (out of scope), so this is detection-only.
- Deliberately NOT faked: **reverb** dereverb and **overlapping-speaker** separation need trained models; a
  cheap heuristic would mostly false-positive, so they're omitted (overlap is still LABELLED by the existing
  Gemini content-map diarization — labelling ≠ separation).
- Surfaced in: GUI "AUDIO QUALITY (raw source)" card (`ResultsPanels`), CLI stage-2 print, computed on clip
  add (`loadMeta` → `clip.audioQuality`).

### Code-switching (中英夾雜) — `TranscriptCorrector`
Added an explicit `codeSwitchRule` to the correction system prompt: the single-locale (zh-TW) recognizer
emits English as one often-garbled Latin token (or drops it) and sometimes writes spoken English as
same-sounding Chinese. The rule tells the corrector to keep English as English, repair a mangled English
token to correct spelling/casing when context is clear, and never transliterate one language into the other.
(Prompt-level fix — pairs with the content-map REFERENCE and the retranscribe stage that already recover the
harder cases.)

### Open / next steps
- **Untested — needs a Mac build.** Watch the CLI `audio quality:` line + `⚠︎` warnings on a clipped clip and
  a music-bed clip; check the code-switch rule on `評測頻道D`/`財經節目E` (code-switch clips) doesn't over-correct clean
  English. Tune `clipWarnFraction` (0.2%), `lowSNRWarnDb` (12).
- Overlap/reverb/music separation remain genuine ML gaps — revisit only if a separation model is in scope.

---

## Session 2026-07-01 (b) — pre-ASR audio conditioning (fast & quiet speech)

Branch: `claude/fast-speech-transcription-7zyzzn` (off `main`).

### Problem
Fast talkers and quiet/fading talkers wreck the transcript in two *different* ways, so they need two
*different* fixes — both applied to the audio BEFORE recognition:
- **Fast** → the recognizer (fixed frame rate) swallows run-together syllables (整年檢壓 for 正念減壓).
- **Quiet / fading** → whole utterance under the recognizer's floor, and the sentence-final particles
  (的/了/嗎) trail off below the VAD threshold and get dropped entirely.

### What changed
New `AudioConditioner.swift` — a single offline pass over the extracted 16 kHz mono audio:
1. **Denoise** (opt-in, default OFF): one-pole ~85 Hz high-pass + gentle downward expander below -45 dBFS.
2. **Normalize + compress** (default ON, near-zero risk): attack/release envelope-follower compressor pulls
   peaks down so makeup gain lifts the whole utterance — the fading tail comes up without the peaks clipping.
   Makeup gain capped at +24 dB so a noise-only clip isn't blown up.
3. **Adaptive slow-down** (default ON): estimates syllable rate from RMS energy peaks (1 CJK syllable ≈ 1
   nucleus peak — no ASR needed), and when it exceeds ~6.5 syl/s time-stretches the audio SLOWER (pitch
   preserved, `AVAudioUnitTimePitch` offline) so each syllable gets more frames. Rate scales inversely with
   speed, clamped to [0.6×, 0.9×]. Normal-paced clips are untouched (rate = 1.0).

`timeScale` maps recognizer timings back onto the source clock (`decodeResults` multiplies by it) — a word at
conditioned-time *t* sits at source-time *t·rate*. The Gemini **retranscribe** span (stage 5) is conditioned
too (normalize + forced slow-down): only its TEXT is used and timing comes from ORIGINAL-clock energy peaks,
so the slow-down needs zero time mapping there.

Conditioning is **pure upside** — any failure (unreadable track, engine error) returns nil and the pipeline
analyzes the untouched extract. Stage-7 timing-preservation invariant is unaffected (both sides use the same
scaled-back `asr.words`).

### Wiring
- `Transcription.transcribe/transcribeVideoAudio` take `conditioning: AudioConditioning` (defaults on).
- `CaptionPipeline.retranscribeSuspectSpans` takes it too; span → WAV (int16) → Gemini `audio/wav`.
- GUI: new "AUDIO CONDITIONING (pre-ASR)" toggles in `ControlsPanel` (`vm.conditioning`).
- CLI: `--no-normalize`, `--no-slow-fast`, `--denoise`.

### Open / next steps
- **Untested — needs a Mac build** (this session was authored on Linux; no Apple toolchain). Build with
  `swift build`, then A/B on the fast clip (`finance_財經節目E`) and a quiet clip: compare dropped-syllable count
  and tail-particle survival with conditioning on/off. Watch the `[NOTICE] conditioned audio …` log line for
  the measured syl/s and chosen stretch rate.
- **Verify SpeechAnalyzer accepts the conditioned int16 CAF** (same format as the original extract, so it
  should — but confirm on first run).
- **Tune thresholds** on real clips: `fastSyllablesPerSecond` (6.5), stretch clamp [0.6, 0.9], compressor
  threshold/ratio (-24 dB, 3:1), gate threshold (-45 dB).
- **Other speech pathologies not yet handled** (surfaced for the user): code-switching / 中英夾雜 (single
  `zh-TW` locale mangles English — the content-map reference partly covers it), overlapping speakers,
  clipping/爆音 (already-clipped samples can't be normalized back — could detect + warn), room reverb
  (smears syllables AND energy peaks), background music.

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
   - **Re-time recovered inserted words** (`rebuildSegment` + `alignBlocks`, envelope threaded via `url`):
     when the map recovers words the recognizer never emitted (Chinese speech that dropped the English
     "HDMI 2.1"), correction now places those units on syllable energy peaks (`placeOnEnergyPeaks`) so they
     appear on the word timeline / on-video caption, not just in the segment text. The timing-preservation
     self-check still calls `applyCorrectedText` WITHOUT an envelope, so it stays a 1:1 count check.
5. **On-video caption overlay** (`PipelineViewModel.captionLines`/`currentCaption`, `ContentView`)
   - Overlays the current caption line on the video player, synced to `currentTime` (global raw-time axis).
6. **Semantic caption line breaks, piggybacked on correction** (`TranscriptionSegment.captionBreaks`)
   - The per-word track is punctuation-stripped, so it can't tell where sentences end (length-chopping looked
     bad). The correction LLM call now ALSO emits soft break hints (¦ markers) at meaning-aware boundaries;
     `correct()` parses them into `captionBreaks` (unit indices) and the overlay splits on them — falling back
     to punctuation, always capped so no line overflows. Zero extra API cost, style-agnostic (interview /
     finance / poetry). Markers are stripped and never counted, so count-lock is unchanged.
   - Decision: pause-based breaking was rejected — hesitation pauses in interviews fire false breaks and it's
     speed-dependent (not universal). Semantic LLM breaks are the one method that generalises.
7. **Verbatim content map** (`MediaDescriber` prompt)
   - The content-map dialogue is the REFERENCE the correction stage compares against, so it must be verbatim.
     The old prompt asked for "key spoken words" per visual shot → on a single-shot podcast (財經節目E) Gemini
     returned ONE 438-char summary block. New prompt demands a VERBATIM, original-language transcript broken
     into short 3–7 s blocks (no summarizing/translating; keep fillers, stutters, code-mixing). Result on the
     same clip: 1 block → 16 short verbatim blocks (avg 26 chars), speaker resolved to the real name (主持人E).
   - `maxTokens` for this call raised to 65536 (the flash/pro/flash-lite output limit, verified via models API)
     so a long clip's verbatim transcript isn't truncated.

### Validation — 5 clips, all timing drift 0, PASS
| clip | type | swapped | highlight |
|---|---|---|---|
| 受訪者A | interview / disfluent | 8–12/255 | 整年檢壓→正念減壓 |
| 講者B | domain jargon | 31/261 | 幹細胞 / 粒線體 / 分泌 / 某大獎得主 |
| 朗讀者C | clean poetry | **3/91** | 願→月; barely changes clean audio (no over-correction) |
| 評測頻道D (評測頻道D) | tech jargon + code-switch | 31/260 | HDR10 / RGB LED; **HDMI 2.1 recovered onto timeline** |
| 財經節目E (showE) | finance + code-switch, fast | 13/383 | 某台語俗諺 (idiom); AI kept |
- Overfit check passed: the aggressive map-reference makes FEW changes on clean audio (朗讀者C: 3) and correct
  changes on jargon — it generalised to domains it was never tuned on. Prompt example genericised (反應/反映).
- Apple ASR granularity confirmed: CJK is per-character (1 char ≈ 1 syllable ≈ 1 token); Latin/English is a
  whole-token unit and is often mangled or dropped (single locale `zh-TW`, no code-switching) — which is
  exactly why the multilingual content-map reference is worth so much.
- Test clips live in `~/Desktop/pp-test/` (not in git): `clean_朗讀者C.mp4`, `jargon_評測頻道D.mp4`, `finance_財經節目E.mp4`
  (60s slices via `yt-dlp --download-sections`), plus the original `受訪者A…`, `講者B…`.

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
- **Clearer progress (NEXT — user's priority for tomorrow)**: stages currently show only a binary
  `running`/`done` (`StageState`), so the slow Content-map stage (Gemini watching the whole clip, 30 s–2 min)
  looks hung — no way to tell it's alive. Make it legible:
  - Per-stage ELAPSED timer while `.running` (e.g. "Content map · 0:23…") — cheapest, immediately reassuring.
  - A sub-status line per stage: "uploading to Gemini / waiting for response / downloading Qwen model 45%".
    The pieces already exist — `Transcription` prints `[NOTICE] extract/transcribe…` to stdout, the Qwen
    sidecar (`mlx_audio`) prints a model-download progress bar to stderr, and Apple `SpeechTranscriber` can
    report progress — surface these into the GUI instead of the console.
  - Optionally a spinner/indeterminate bar on the active stage dot in `PipelineStage`/`ResultsPanels`.
  - Wire point: `StageState`/`PipelineStage` (PipelineViewModel.swift) drive the stage dots; add an elapsed
    timestamp + optional `detail: String` and render it in the CLIP stage view.
- **Long-term overfit watch**: the "prefer the map" rule COULD trade an ASR-correct word for a map-wrong one.
  2 clips showed only improvements, but validate on more, varied clips; consider logging map-swap accuracy.
- **Tighten inserted-word timing**: recovered insertions (HDMI 2.1) are placed on energy peaks within the
  span of the single ASR word they replaced, so they can be cramped (~40 ms each). Expand the placement span
  into the neighbouring silence gap for more natural timing.
- **Manual-edit re-timing** (user idea): when a human fixes text both ASR and map missed, re-time that span
  with the existing `placeOnEnergyPeaks` (1 CJK char ≈ 1 energy peak) — the same path `rebuildSegment` now
  uses for map-recovered insertions. Would need a GUI "edit caption line → re-time span" hook.
- **Export cut video** (deferred — preview via "Joined + cuts" is enough for now): ffmpeg `select/aselect +
  concat` to render the ripple cut. Also considered: `silencedetect` (sturdier than our RMS valley),
  `afftdn`/`loudnorm` denoise+normalize before ASR to reduce recognition errors at the source.

### Test clips used
`~/Desktop/pp-test/受訪者A_訪談測試.mp4` (2-speaker interview, disfluent),
`~/Desktop/pp-test/講者B_演講測試.mp4` (domain talk, heavy jargon). Both: timing drift 0, PASS.
