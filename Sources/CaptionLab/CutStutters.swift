import Foundation

// Stage 6 — "cut stutters / disfluencies", reproducing the app's remove_words flow.
//
// In the main app this decision is made by the LLM agent (it reads the transcript and calls remove_words
// with the word ids to cut); WordCutPlanner then turns selected words into ripple-delete FrameRanges.
// TranscriptCorrector deliberately PRESERVES stutters/false-starts (去去去去 stays 去去去去), so they are
// still present in the corrected words and this stage is what removes them.
//
// WordCutPlanner is byte-faithful and works in FRAMES with clipStart/clipEnd; the ASR words are in
// SECONDS. All unit conversion lives in this wrapper (nominal fps = the video's fps if readable, else 30).
enum CutStutters {
    /// Default disfluencies (byte-faithful from EditorViewModel+AutoCut.swift `defaultFillers`).
    /// Only unambiguous ones (English "um/uh…" + CJK "嗯/呃…"). Words like "like/so/那個/就是" are often
    /// meaningful, so they're opt-in via a custom list, never default.
    // 啊/唉 excluded: they're meaningful CJK sentence-final particles (好啊/對啊/是啊), not fillers — cutting
    // them orphans the preceding character.
    static let defaultFillers: Set<String> = ["um", "uh", "uhh", "uhm", "umm", "er", "err", "erm", "ah", "hmm", "mm", "mhm", "嗯", "呃"]

    /// `marks` consumes the corrector's ⟨⟩ disfluency marks (ONE semantic pass owns correction, breaks AND
    /// cuts — see TranscriptCorrector); `heuristic` is the offline/no-marks fallback.
    enum Detector: String, Sendable, CaseIterable { case marks, heuristic }

    struct Result: Sendable {
        let mode: Detector
        let cutIndices: [Int]
        /// Cut spans in SOURCE SECONDS (converted back from the planner's frame ranges).
        let cutRangesSeconds: [ClosedRange<Double>]
        let secondsSaved: Double
        /// Words that survive the cut (index not in `cutIndices`).
        let keptWords: [TranscriptionWord]
        /// The words that were cut, for display.
        let cutWords: [TranscriptionWord]
        /// True when `marks` was requested but no marks were available (correction failed) → heuristic ran.
        let fellBack: Bool
    }

    /// Global word indices from the corrector's per-segment disfluency marks — pure bookkeeping, no model
    /// call. Positional unit↔word mapping within each segment, the same approximation captions use.
    /// `includeStylistic` folds in the tier-2 ⟪⟫ discourse-marker padding on top of the always-removable
    /// ⟨⟩ tier — the caller turns it on via the "cut stylistic padding" switch / --cut-padding (independent
    /// of keep-gap aggressiveness), so a conservative edit never removes a 那個/就是/然後 doing real work.
    static func indicesFromMarks(result: TranscriptionResult, includeStylistic: Bool = false) -> [Int] {
        var out: [Int] = []
        var wi = 0
        let words = result.words
        for seg in result.segments {
            var segIdx: [Int] = []
            while wi < words.count {
                let w = words[wi]
                guard let s = w.start, let e = w.end else { wi += 1; continue }   // untimed → uncuttable
                let mid = (s + e) / 2
                if mid < seg.start { wi += 1; continue }
                if mid >= seg.end { break }
                segIdx.append(wi); wi += 1
            }
            let units = includeStylistic ? (seg.cutUnits + seg.stylisticCutUnits) : seg.cutUnits
            for u in units where u >= 0 && u < segIdx.count { out.append(segIdx[u]) }
        }
        return Array(Set(out)).sorted()
    }

    static func plan(
        words: [TranscriptionWord], fps: Double,
        aggressiveness: CutAggressiveness, detector: Detector, url: URL? = nil,
        marks: [Int]? = nil
    ) async -> Result {
        var fellBack = false
        var mode = detector
        var indices: [Int]
        if detector == .marks, let marks {
            indices = marks
        } else {
            if detector == .marks { fellBack = true }
            mode = .heuristic
            indices = heuristicCutIndices(words: words)
        }
        let cutSet = Set(indices.filter { $0 >= 0 && $0 < words.count })

        // Seconds → frames for the planner. A word with no timing can't be placed; give it a zero-length
        // frame span so the planner filters it (endFrame > startFrame), keeping index alignment intact.
        let plannerWords: [WordCutPlanner.Word] = words.enumerated().map { i, w in
            guard let s = w.start, let e = w.end else { return WordCutPlanner.Word(startFrame: 0, endFrame: 0, selected: false) }
            return WordCutPlanner.Word(
                startFrame: Int((s * fps).rounded()),
                endFrame: Int((e * fps).rounded()),
                selected: cutSet.contains(i))
        }
        let timed = words.compactMap { w -> (Double, Double)? in
            guard let s = w.start, let e = w.end else { return nil }
            return (s, e)
        }
        let clipStart = timed.map { Int(($0.0 * fps).rounded()) }.min() ?? 0
        let clipEnd = timed.map { Int(($0.1 * fps).rounded()) }.max() ?? 0
        let keepGapFrames = Int((aggressiveness.keptGapMs / 1000.0 * fps).rounded())

        let ranges = WordCutPlanner.cutRanges(
            words: plannerWords, clipStart: clipStart, clipEnd: clipEnd, keepGapFrames: keepGapFrames)

        // Frames → seconds for display + "seconds saved".
        var rangesSeconds = ranges.map { (Double($0.start) / fps)...(Double($0.end) / fps) }
        // Word timings come from the recognizer, whose boundaries sit ON the syllable rather than in the
        // silence around it — so a frame-snapped cut can slice mid-syllable and leave an audible fragment
        // ("去去去" cut but the first 去's onset survives). Nudge each boundary to the quietest instant in a
        // small window so the splice lands in a natural pause. Forced-alignment (Qwen) boundaries were worse
        // here (zero-width tokens + gaps), so we refine the ASR boundaries acoustically instead.
        if let url, let env = try? await AudioEnvelopeExtractor.extract(from: url) {
            rangesSeconds = snapToValleys(rangesSeconds, envelope: env)
        }
        let secondsSaved = rangesSeconds.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }

        let kept = words.enumerated().filter { !cutSet.contains($0.offset) }.map(\.element)
        let cut = words.enumerated().filter { cutSet.contains($0.offset) }.map(\.element)
        return Result(mode: mode, cutIndices: cutSet.sorted(), cutRangesSeconds: rangesSeconds,
                      secondsSaved: secondsSaved, keptWords: kept, cutWords: cut, fellBack: fellBack)
    }

    // NOTE: the old per-word LLM cut detector is GONE by design. Cut decisions belong to the ONE semantic
    // pass in TranscriptCorrector (which reads full sentences with references and marks disfluencies with
    // ⟨⟩); this stage only executes those marks mechanically. A second model judging a bare one-char-per-line
    // word list is what mis-cut legitimate reduplications like 常常.

    /// Heuristic fallback (`--cut-heuristic`): mark consecutive duplicate words (same normalized text)
    /// except the LAST in each run, plus any word in `defaultFillers`.
    /// Nudge each cut boundary to the lowest-energy (quietest) instant within ±`maxShift` seconds, so the
    /// splice lands in a pause instead of through a syllable. The window is deliberately tiny so a cut can
    /// never grow into a neighbouring KEPT syllable; if snapping ever inverts a range it is left untouched.
    /// Snapped ranges can touch, so overlaps are merged to keep the ripple clean.
    static func snapToValleys(_ ranges: [ClosedRange<Double>], envelope env: AudioEnvelope,
                              maxShift: Double = 0.07) -> [ClosedRange<Double>] {
        let hop = env.hopSeconds, s = env.samples
        guard hop > 0, s.count > 2 else { return ranges }
        func snap(_ t: Double) -> Double {
            let center = max(0, min(s.count - 1, Int((t / hop).rounded())))
            let w = max(1, Int((maxShift / hop).rounded()))
            let lo = max(0, center - w), hi = min(s.count - 1, center + w)
            var bestI = center, bestE = s[center]
            for i in lo...hi where s[i] < bestE { bestE = s[i]; bestI = i }
            return Double(bestI) * hop
        }
        let snapped = ranges.map { r -> ClosedRange<Double> in
            let a = snap(r.lowerBound), b = snap(r.upperBound)
            return b > a ? a...b : r
        }
        let sorted = snapped.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for r in sorted {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }

    static func heuristicCutIndices(words: [TranscriptionWord], fillers: Set<String> = defaultFillers) -> [Int] {
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
        var cut: [Int] = []
        var i = 0
        while i < words.count {
            let n = norm(words[i].text)
            // A run of consecutive identical words: cut all but the last. EXCEPT an exact PAIR of one CJK
            // character — that's almost always a legitimate reduplicated word (常常/剛剛/慢慢), not a stutter;
            // real CJK stutters run 3+ (去去去去). English pairs ("the the") stay cut.
            var j = i
            while j + 1 < words.count, norm(words[j + 1].text) == n, !n.isEmpty { j += 1 }
            let cjkPair = (j == i + 1) && n.count == 1 && n.first.map(CaptionBuilder.isCJKChar) == true
            if j > i, !cjkPair { cut.append(contentsOf: i..<j) }   // keep index j (the last), cut i..<j
            // Fillers (single words) — cut every occurrence not already covered.
            for k in i...j where fillers.contains(norm(words[k].text)) && !cut.contains(k) { cut.append(k) }
            i = j + 1
        }
        return cut.sorted()
    }
}
