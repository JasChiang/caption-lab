import AVFoundation
import Foundation
import Observation
import SwiftUI

// MARK: - Shared stage / result value types

enum StageState: Equatable { case pending, running, done, skipped, failed(String) }

struct PipelineStage: Identifiable, Equatable {
    let id: Int
    let name: String
    var state: StageState = .pending
    /// When this stage entered `.running` — drives the live elapsed timer so a slow stage never looks hung.
    var startedAt: Date? = nil
    /// Optional sub-status for the active stage (e.g. "Gemini watching the whole clip").
    var detail: String? = nil
}

struct DiffChange: Identifiable { let id = UUID(); let from: String; let to: String }
struct RetranscribeRow: Identifiable { let id = UUID(); let t: String; let from: String; let to: String }

let stageDefs: [(Int, String)] = [
    (1, "Content map"), (2, "ASR"), (3, "Glossary"), (4, "Correct"),
    (5, "Retranscribe"), (6, "Cut"), (7, "Timing"),
]
func makeStages() -> [PipelineStage] { stageDefs.map { PipelineStage(id: $0.0, name: $0.1) } }

// MARK: - Clip (one video in the track, with its own pipeline results)

@MainActor
@Observable
final class ClipModel: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }

    // Media
    var duration: Double = 0
    var fps: Double = 30
    var envelope: AudioEnvelope?
    /// Raw-source quality analysis (clipping / SNR) — computed on add, surfaced as warnings.
    var audioQuality: AudioQuality.Report?
    var audioWarnings: [String] { audioQuality?.warnings ?? [] }

    // Per-clip stage progress
    var stages: [PipelineStage] = makeStages()

    // Per-clip results
    var contentLabel: String?
    var contentSegments: [ContentSegment] = []
    var asr: TranscriptionResult?
    var harvested: [String] = []
    var effectiveGlossary: [String] = []
    var correctionSucceeded = true
    var diffChanges: [DiffChange] = []
    var atomicTerms: [String] = []
    var corrected: TranscriptionResult?
    var afterRetranscribe: TranscriptionResult?
    var retranscribeRows: [RetranscribeRow] = []
    var cut: CutStutters.Result?
    var timingPass: Bool?
    var timingDrift = 0
    var timingTextSwaps = 0

    // Qwen (MLX) forced-aligner A/B — independent timing backend on the SAME corrected text.
    var qwenState: StageState = .pending
    var qwenWords: [TranscriptionWord] = []
    var qwenError: String?
    var qwenWarning: String?

    init(url: URL) { self.url = url }

    /// Words to plot for this clip (post-retranscribe if available, else corrected, else raw ASR).
    var words: [TranscriptionWord] { afterRetranscribe?.words ?? corrected?.words ?? asr?.words ?? [] }
    /// Cut spans in this clip's LOCAL source seconds.
    var cutSpans: [ClosedRange<Double>] { cut?.cutRangesSeconds ?? [] }
    var secondsSaved: Double { cut?.secondsSaved ?? 0 }
    /// Effective (post-cut) duration.
    var effectiveDuration: Double { max(0, duration - secondsSaved) }

    func stateOf(_ id: Int) -> StageState { stages.first(where: { $0.id == id })?.state ?? .pending }
    func mark(_ id: Int, _ state: StageState) {
        guard let i = stages.firstIndex(where: { $0.id == id }) else { return }
        if case .running = state { stages[i].startedAt = Date() } else { stages[i].detail = nil }
        stages[i].state = state
    }
    /// Set the active stage's sub-status line (cleared automatically when the stage leaves `.running`).
    func detail(_ id: Int, _ text: String?) { if let i = stages.firstIndex(where: { $0.id == id }) { stages[i].detail = text } }
    /// The stage currently running, if any — for the live status line.
    var runningStage: PipelineStage? { stages.first { $0.state == .running } }
    func resetStages() { stages = makeStages() }
}

// MARK: - Track view model

@MainActor
@Observable
final class PipelineViewModel {

    // Inputs
    var clips: [ClipModel] = []
    var selectedClipID: UUID?
    var selectedClip: ClipModel? { clips.first(where: { $0.id == selectedClipID }) ?? clips.first }
    var apiKey: String = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
    var glossaryText: String = ""
    var skipRetranscribe = false
    var cutDetector: CutStutters.Detector = .llm
    var aggressiveness: CutAggressiveness = .balanced
    var language = "Traditional Chinese"
    /// GUI defaults to PRO: the 財經節目E 0:17 case showed flash-tier ears miss marginal fast speech that pro
    /// hears (and the map is the reference everything downstream leans on). CLI keeps the cheap flash
    /// default for batch testing — override with --model there.
    var model = "gemini-pro-latest"
    var conditioning = AudioConditioning()
    var alignerMode: AlignerMode = .apple
    var qwenAvailable: Bool { QwenAligner.isAvailable() }

    // Playback
    let player = AVPlayer()
    var currentTime: Double = 0          // GLOBAL RAW seconds (mapped from composition time)
    var previewCutsApplied = false
    var isRunning = false
    var statusLine = "Drop one or more videos to build a track."
    private var timeObserver: Any?
    private var keptSegments: [KeptSeg] = []   // composition ↔ raw-global time map

    struct KeptSeg { let rawStart: Double; let rawEnd: Double; let compStart: Double }

    private let concurrencyCap = 2

    // MARK: Global timeline geometry

    /// Total RAW track duration (clips concatenated at full length).
    var totalRawDuration: Double { clips.reduce(0) { $0 + $1.duration } }
    /// Total duration after cuts.
    var totalCutDuration: Double { clips.reduce(0) { $0 + $1.effectiveDuration } }
    var totalSecondsSaved: Double { clips.reduce(0) { $0 + $1.secondsSaved } }

    /// RAW-global start offset of each clip (by index), concatenated in order.
    func rawOffset(of index: Int) -> Double {
        clips.prefix(index).reduce(0) { $0 + $1.duration }
    }

    // MARK: - On-video captions (simple overlay)

    /// A displayable caption phrase on the GLOBAL raw-time axis.
    struct CaptionLine: Equatable { let start: Double; let end: Double; let text: String }

    /// Caption lines for the on-video overlay. The per-word track is punctuation-STRIPPED, so it can't tell
    /// where sentences end. Instead we break each corrected SEGMENT's display units at the LLM's ¦ break
    /// hints (semantic, style-agnostic) when present, else at punctuation, always capped so no line
    /// overflows — and map each chunk back onto its words' timings. Times are global raw seconds.
    private var captionLineCache: [CaptionLine] = []

    /// Cached caption lines — returned to `currentCaption` on every playhead tick. Rebuilt only when results
    /// or clip layout change (`rebuildCaptionCache`), NOT per frame: recomputing the whole list ~33×/s during
    /// playback previously pegged the CPU and made the GUI sluggish.
    func captionLines() -> [CaptionLine] { captionLineCache }

    /// Recompute the caption-line cache from current clip results. Cheap; call whenever results/layout change.
    func rebuildCaptionCache() {
        var lines: [CaptionLine] = []
        for (idx, clip) in clips.enumerated() {
            let off = rawOffset(of: idx)
            guard let result = clip.afterRetranscribe ?? clip.corrected else { continue }
            let words = result.words
            for seg in result.segments {
                let segWords = words.filter {
                    guard let s = $0.start, let e = $0.end else { return false }
                    let m = (s + e) / 2
                    return m >= seg.start && m < seg.end
                }
                guard !segWords.isEmpty else { continue }
                let du = CaptionBuilder.units(seg.text, keepPunctuation: true)   // units keep trailing punctuation
                guard !du.isEmpty else { continue }
                // Inter-word silence at each unit boundary (positional unit≈word mapping, same as the chunk
                // loop below). Lets a forced break land on a real breath instead of mid-phrase — the main
                // lever for fast speech, where semantic ¦ hints are sparse and pauses are few but real.
                var gaps = [Double](repeating: 0, count: du.count)
                let m = min(du.count, segWords.count)
                if m >= 2 {
                    for k in 1..<m {
                        if let e0 = segWords[k - 1].end, let s1 = segWords[k].start { gaps[k] = max(0, s1 - e0) }
                    }
                }
                var s = 0, wi = 0
                for e in captionStops(du: du, llm: seg.captionBreaks, gaps: gaps, maxUnits: 16) {
                    guard e > s else { continue }
                    let last = (e == du.count)
                    let n = last ? (segWords.count - wi) : min(e - s, segWords.count - wi)
                    if n > 0 {
                        let take = segWords[wi..<wi + n]; wi += n
                        let text = du[s..<min(e, du.count)].joined().trimmingCharacters(in: .whitespaces)
                        if let a = take.first?.start, let b = take.last?.end, !text.isEmpty {
                            lines.append(CaptionLine(start: off + a, end: off + b, text: text))
                        }
                    }
                    s = e
                }
            }
        }
        captionLineCache = lines
    }

    /// Unit indices to break AFTER (the list always ends at `du.count`): the LLM's ¦ hints when present, else
    /// punctuation-derived, then extra breaks inserted so no chunk exceeds `maxUnits` (preferring a comma).
    private func captionStops(du: [String], llm: [Int], gaps: [Double] = [], maxUnits: Int) -> [Int] {
        var brk = Set<Int>()
        if !llm.isEmpty {
            // Drop an LLM hint that would strand a tail shorter than 2 units (same orphan-tail rule as below).
            for b in llm where b > 0 && b <= du.count - 2 { brk.insert(b) }
        } else {
            var since = 0
            for (i, u) in du.enumerated() where i < du.count - 1 {
                since += 1
                let hard = u.contains { "。！？!?…".contains($0) }
                let soft = u.contains { "，、；：,;".contains($0) }
                if hard || (soft && since >= 8) { brk.insert(i + 1); since = 0 }
            }
        }
        // Gemini's ¦ breaks are AUTHORITATIVE — no forced length cap on top (a hard cut mid-thought reads
        // worse than an occasionally long line; the overlay wraps). The cap below only applies to the
        // punctuation FALLBACK, where a no-punctuation run-on would otherwise become one endless line.
        guard llm.isEmpty else { return brk.sorted() + [du.count] }
        let stops = [0] + brk.sorted() + [du.count]
        for k in 0..<(stops.count - 1) {
            var s = stops[k]
            let e = stops[k + 1]
            while e - s > maxUnits {
                // No orphan tails: every cut leaves at least `minTail` units before the next stop. Without
                // this, a 17-unit chunk becomes 16 + one stranded character (「…十分的了」/「解」).
                let minTail = 2
                let hardCut = min(s + maxUnits, e - minTail)
                guard hardCut > s else { break }
                let lo = s + maxUnits / 2, hi = hardCut
                // 1) a comma/semicolon in the window (semantic break); else
                // 2) the biggest breath (inter-word pause > 40 ms) in the window (acoustic break); else
                // 3) a hard cut (capped so the tail keeps `minTail`).
                let commaCut = stride(from: hi, through: lo, by: -1)
                    .first { du[$0 - 1].contains { "，、；：,;".contains($0) } }
                var cut = commaCut ?? hardCut
                if commaCut == nil, !gaps.isEmpty, lo <= hi {
                    var bestGap = 0.04, best = -1
                    for p in lo...hi where p < gaps.count && gaps[p] > bestGap { bestGap = gaps[p]; best = p }
                    if best >= 0 { cut = best }
                }
                brk.insert(cut); s = cut
            }
        }
        return brk.sorted() + [du.count]
    }

    /// Caption text to overlay at the current playhead (global raw time), or "" when between lines.
    var currentCaption: String {
        let t = currentTime
        return captionLines().last { $0.start - 0.05 <= t && t <= $0.end + 0.2 }?.text ?? ""
    }

    // MARK: - Track editing

    func addFiles(_ urls: [URL]) {
        let videos = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !videos.isEmpty else { return }
        for url in videos {
            let clip = ClipModel(url: url)
            clips.append(clip)
            Task { await loadMeta(clip); await rebuildComposition() }
        }
        if selectedClipID == nil { selectedClipID = clips.first?.id }
        statusLine = "\(clips.count) clip(s) in track."
    }

    func remove(_ clip: ClipModel) {
        clips.removeAll { $0.id == clip.id }
        Task { await rebuildComposition() }
    }

    func move(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
        Task { await rebuildComposition() }
    }

    private func loadMeta(_ clip: ClipModel) async {
        let asset = AVURLAsset(url: clip.url)
        if let d = try? await asset.load(.duration) { clip.duration = d.seconds }
        if let track = try? await asset.tracksSafely(withMediaType: .video).first,
           let rate = try? await track.load(.nominalFrameRate), rate > 0 {
            clip.fps = Double(rate)
        } else { clip.fps = 30 }
        // Heavy audio analysis (waveform envelope + SoundAnalysis music / clipping / SNR) runs OFF the main
        // actor at LOW priority, so dropping a clip never blocks or janks the UI. Results publish back on the
        // main actor when ready — the waveform and AUDIO QUALITY card fill in a moment after the clip appears.
        let url = clip.url
        Task.detached(priority: .utility) {
            let envelope = try? await AudioEnvelopeExtractor.extract(from: url)
            let quality = await AudioQuality.analyze(url: url)
            await MainActor.run {
                clip.envelope = envelope
                clip.audioQuality = quality
            }
        }
    }

    // MARK: - Composition (joined, seekable; raw or cuts-applied)

    private func installTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = self.compToRaw(time.seconds)
            }
        }
    }

    /// Rebuild the joined composition from the ordered clips. In cuts-applied mode each clip is inserted
    /// MINUS its stutter/filler ranges, so playback is the real tightened track. Also rebuilds the
    /// composition↔raw-global time map used for the playhead and word-chip seeking.
    func rebuildComposition() async {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }

        var map: [KeptSeg] = []
        var compCursor = CMTime.zero
        var rawCursor = 0.0

        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            let assetVideo = try? await asset.tracksSafely(withMediaType: .video).first
            let assetAudio = try? await asset.tracksSafely(withMediaType: .audio).first
            let dur = clip.duration > 0 ? clip.duration : ((try? await asset.load(.duration))?.seconds ?? 0)
            guard dur > 0 else { rawCursor += dur; continue }

            let cuts = previewCutsApplied ? RippleEngine.mergeSecondRanges(clip.cutSpans) : []
            let kept = complement(of: cuts, over: 0...dur)
            for local in kept {
                let range = CMTimeRange(start: CMTime(seconds: local.lowerBound, preferredTimescale: 600),
                                        end: CMTime(seconds: local.upperBound, preferredTimescale: 600))
                if let assetVideo { try? vTrack.insertTimeRange(range, of: assetVideo, at: compCursor) }
                if let assetAudio { try? aTrack.insertTimeRange(range, of: assetAudio, at: compCursor) }
                map.append(KeptSeg(rawStart: rawCursor + local.lowerBound,
                                   rawEnd: rawCursor + local.upperBound,
                                   compStart: compCursor.seconds))
                compCursor = compCursor + range.duration
            }
            rawCursor += dur
        }

        keptSegments = map
        installTimeObserver()
        player.replaceCurrentItem(with: AVPlayerItem(asset: comp))
        rebuildCaptionCache()
    }

    /// Complement of `cuts` within `[bounds]` → the kept sub-ranges, in order.
    private func complement(of cuts: [ClosedRange<Double>], over bounds: ClosedRange<Double>) -> [ClosedRange<Double>] {
        guard !cuts.isEmpty else { return [bounds] }
        var kept: [ClosedRange<Double>] = []
        var cursor = bounds.lowerBound
        for c in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lo = max(bounds.lowerBound, c.lowerBound), hi = min(bounds.upperBound, c.upperBound)
            if lo > cursor { kept.append(cursor...lo) }
            cursor = max(cursor, hi)
        }
        if cursor < bounds.upperBound { kept.append(cursor...bounds.upperBound) }
        return kept.filter { $0.upperBound > $0.lowerBound }
    }

    /// Composition time → raw-global time (identity in raw mode).
    func compToRaw(_ compT: Double) -> Double {
        guard !keptSegments.isEmpty else { return compT }
        for seg in keptSegments {
            let len = seg.rawEnd - seg.rawStart
            if compT >= seg.compStart && compT <= seg.compStart + len + 0.0001 {
                return seg.rawStart + (compT - seg.compStart)
            }
        }
        return keptSegments.last.map { $0.rawEnd } ?? compT
    }

    /// Raw-global time → composition time. If the raw time falls inside a cut gap, snaps to the next kept
    /// segment's start.
    func rawToComp(_ rawT: Double) -> Double {
        guard !keptSegments.isEmpty else { return rawT }
        for seg in keptSegments where rawT >= seg.rawStart && rawT < seg.rawEnd {
            return seg.compStart + (rawT - seg.rawStart)
        }
        // In a gap or past the end → nearest following segment start, else clamp to end.
        if let next = keptSegments.first(where: { $0.rawStart >= rawT }) { return next.compStart }
        return keptSegments.last.map { $0.compStart + ($0.rawEnd - $0.rawStart) } ?? rawT
    }

    func seekRaw(to rawSeconds: Double) {
        let compT = rawToComp(max(0, rawSeconds))
        player.seek(to: CMTime(seconds: compT, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    func setPreviewCutsApplied(_ on: Bool) {
        previewCutsApplied = on
        Task { await rebuildComposition() }
    }

    // MARK: - Run pipeline (per clip, capped concurrency)

    func run() {
        guard !clips.isEmpty, !isRunning else { return }
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { statusLine = "Set a GEMINI_API_KEY first."; return }
        setenv("GEMINI_API_KEY", apiKey.trimmingCharacters(in: .whitespaces), 1)
        isRunning = true
        for c in clips { c.resetStages() }
        Task {
            defer { isRunning = false }
            let list = clips
            var i = 0
            while i < list.count {
                let batch = Array(list[i..<min(i + concurrencyCap, list.count)])
                await withTaskGroup(of: Void.self) { group in
                    for clip in batch { group.addTask { await self.runClip(clip) } }
                }
                i += concurrencyCap
            }
            statusLine = "Track pipeline complete — \(clips.count) clip(s), \(String(format: "%.2f", totalSecondsSaved))s cuttable."
            await rebuildComposition()
        }
    }

    private func runClip(_ clip: ClipModel) async {
        clip.qwenState = .pending; clip.qwenWords = []; clip.qwenError = nil; clip.qwenWarning = nil
        let manual = glossaryText.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // [1] Content map
        clip.mark(1, .running)
        clip.detail(1, "Gemini watching the whole clip (30s–2min)")
        do {
            let r = try await MediaDescriber.describeVideoContentMap(url: clip.url, language: language, model: model)
            clip.contentSegments = r.segments; clip.contentLabel = r.label; clip.mark(1, .done)
        } catch { clip.mark(1, .failed(error.localizedDescription)) }

        // [2] ASR
        clip.mark(2, .running)
        do { clip.asr = try await Transcription.transcribeVideoAudio(videoURL: clip.url, conditioning: conditioning); clip.mark(2, .done) }
        catch { clip.mark(2, .failed(error.localizedDescription)); return }
        guard let asr = clip.asr else { return }

        // [3] Glossary
        clip.mark(3, .running)
        clip.harvested = await CaptionPipeline.contentMapGlossaryTerms(contentSegments: clip.contentSegments)
        clip.effectiveGlossary = Array(Set(clip.harvested + manual)).sorted()
        clip.mark(3, .done)

        // [4] Correction
        clip.mark(4, .running)
        let corr = await TranscriptCorrector.correct(asr, model: model, glossary: clip.effectiveGlossary,
                                                     contentSegments: clip.contentSegments, url: clip.url)
        clip.correctionSucceeded = corr.corrected
        clip.diffChanges = corr.changes.map { DiffChange(from: $0.from, to: $0.to) }
        clip.atomicTerms = corr.result.atomicTerms
        clip.corrected = corr.result
        clip.mark(4, corr.corrected ? .done : .failed("LLM correction failed — raw transcript"))

        // [5] Retranscribe
        var working = corr.result
        if skipRetranscribe { clip.mark(5, .skipped) }
        else if clip.contentSegments.isEmpty { clip.mark(5, .skipped) }
        else {
            clip.mark(5, .running)
            clip.detail(5, "re-transcribing suspect spans with Gemini audio")
            var cache: [String: String] = [:]
            let r = await CaptionPipeline.retranscribeSuspectSpans(
                result: corr.result, url: clip.url, contentSegments: clip.contentSegments, spanCache: &cache,
                conditioning: conditioning, model: model)
            working = r.result
            clip.retranscribeRows = r.retranscribes.map { RetranscribeRow(t: $0.t, from: $0.from, to: $0.to) }
            clip.mark(5, .done)
        }
        clip.afterRetranscribe = working

        // [6] Cut stutters (per clip; WordCutPlanner runs within this clip's own frame span)
        clip.mark(6, .running)
        clip.cut = await CutStutters.plan(words: working.words, fps: clip.fps,
                                          aggressiveness: aggressiveness, detector: cutDetector, url: clip.url)
        clip.mark(6, .done)

        // [7] Timing-preservation check
        clip.mark(7, .running)
        let finalSegs = working.segments
        let writeback = TranscriptCorrector.applyCorrectedText(to: asr.words, segments: finalSegs, corrected: finalSegs.map(\.text))
        var drift = 0
        if writeback.count == asr.words.count {
            for (a, b) in zip(asr.words, writeback) where a.start != b.start || a.end != b.end { drift += 1 }
            clip.timingTextSwaps = zip(asr.words, writeback).filter { $0.text != $1.text }.count
        } else { drift = -1 }
        clip.timingDrift = max(0, drift)
        clip.timingPass = (drift == 0)
        clip.mark(7, drift == 0 ? .done : .failed("timing drift"))
        rebuildCaptionCache()   // this clip's captions are ready — refresh without waiting for the batch end

        // Qwen (MLX) forced-aligner backend — aligns the FINAL corrected text directly to audio.
        if alignerMode.runsQwen { await alignQwen(clip, text: working.text, language: working.language) }
    }

    private func alignQwen(_ clip: ClipModel, text: String, language: String?) async {
        guard QwenAligner.isAvailable() else {
            clip.qwenState = .failed("not set up"); clip.qwenError = QwenAlignerError.notSetUp.localizedDescription; return
        }
        clip.qwenState = .running
        clip.qwenError = nil
        clip.qwenWarning = clip.duration > QwenAligner.maxAudioSeconds
            ? String(format: "Clip is %.0fs (> %.0fs aligner limit) — timings may be unreliable; not truncated.", clip.duration, QwenAligner.maxAudioSeconds)
            : nil
        do {
            clip.qwenWords = try await QwenAligner.align(text: text, language: language, url: clip.url)
            clip.qwenState = .done
        } catch {
            clip.qwenWords = []; clip.qwenError = error.localizedDescription; clip.qwenState = .failed("align failed")
        }
    }

    /// Run only the Qwen aligner for every clip that already has a corrected transcript — for switching to
    /// Qwen/Both A/B after a full run without re-billing the Gemini stages.
    func runQwen() {
        guard !isRunning, alignerMode.runsQwen else { return }
        guard QwenAligner.isAvailable() else { statusLine = QwenAlignerError.notSetUp.localizedDescription; return }
        let targets = clips.filter { $0.afterRetranscribe != nil }
        guard !targets.isEmpty else { statusLine = "Run the pipeline first, then align with Qwen."; return }
        isRunning = true
        Task {
            defer { isRunning = false }
            for clip in targets {   // serial: subprocess is serialized anyway; keeps status readable
                await alignQwen(clip, text: clip.afterRetranscribe?.text ?? "", language: clip.afterRetranscribe?.language)
            }
            statusLine = "Qwen alignment complete for \(targets.count) clip(s)."
        }
    }

    /// Re-run stage 6 (cut) + timing for every clip after the user changes aggressiveness / detector.
    func rerunCut() {
        guard !clips.isEmpty, !isRunning else { return }
        setenv("GEMINI_API_KEY", apiKey.trimmingCharacters(in: .whitespaces), 1)
        isRunning = true
        Task {
            defer { isRunning = false }
            await withTaskGroup(of: Void.self) { group in
                for clip in clips where clip.afterRetranscribe != nil {
                    group.addTask {
                        await MainActor.run { clip.mark(6, .running) }
                        let words = await MainActor.run { clip.afterRetranscribe?.words ?? [] }
                        let fps = await MainActor.run { clip.fps }
                        let r = await CutStutters.plan(words: words, fps: fps, aggressiveness: self.aggressiveness, detector: self.cutDetector)
                        await MainActor.run { clip.cut = r; clip.mark(6, .done) }
                    }
                }
            }
            await rebuildComposition()
        }
    }
}

extension RippleEngine {
    /// Merge overlapping second-ranges (thin wrapper over the frame-based mergeRanges, for composition use).
    static func mergeSecondRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for r in sorted {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }
}
