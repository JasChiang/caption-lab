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

    enum Detector: String, Sendable, CaseIterable { case llm, heuristic }

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
        let llmFellBack: Bool
    }

    static func plan(
        words: [TranscriptionWord], fps: Double,
        aggressiveness: CutAggressiveness, detector: Detector
    ) async -> Result {
        var llmFellBack = false
        var mode = detector
        var indices: [Int]
        if detector == .llm {
            if let llm = await llmCutIndices(words: words) {
                indices = llm
            } else {
                llmFellBack = true; mode = .heuristic
                indices = heuristicCutIndices(words: words)
            }
        } else {
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
        let rangesSeconds = ranges.map { (Double($0.start) / fps)...(Double($0.end) / fps) }
        let secondsSaved = ranges.reduce(0.0) { $0 + Double($1.length) / fps }

        let kept = words.enumerated().filter { !cutSet.contains($0.offset) }.map(\.element)
        let cut = words.enumerated().filter { cutSet.contains($0.offset) }.map(\.element)
        return Result(mode: mode, cutIndices: cutSet.sorted(), cutRangesSeconds: rangesSeconds,
                      secondsSaved: secondsSaved, keptWords: kept, cutWords: cut, llmFellBack: llmFellBack)
    }

    /// LLM detector (default): send the numbered word list and ask for the indices of redundant stutter
    /// repeats / false starts / fillers to remove, KEEPING the final clean instance of a repeated run.
    /// Structured JSON `{"cut":[int]}` (same schema-locked pattern as TranscriptCorrector). Returns nil if
    /// every attempt fails, so the caller can fall back to the heuristic.
    static func llmCutIndices(words: [TranscriptionWord]) async -> [Int]? {
        guard !words.isEmpty else { return [] }
        let numbered = words.enumerated().map { "\($0). \($1.text)" }.joined(separator: "\n")
        let system = """
        You are cleaning a speech transcript for a video editor that ripple-DELETES the words you name. \
        Each line is `index. word`. Return the indices of words that are REDUNDANT DISFLUENCIES safe to \
        remove without changing meaning: stutter repeats and false starts (在 in 在在在 or 去去去去 — keep \
        only the LAST, clean instance of the repeated run), abandoned restarts, and filler words \
        (um, uh, er, 嗯, 呃). Do NOT remove meaningful repetition (deliberate emphasis like 很好很好, or a \
        repeated word that carries meaning), and never remove a word that is part of the actual sentence. \
        When several identical words run consecutively, keep the final one and cut the earlier duplicates. \
        Return a JSON object {"cut":[…]} whose `cut` array holds the integer indices to remove (may be empty).
        """
        let prompt = "Word list (index. word):\n\(numbered)"
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["cut": ["type": "array", "items": ["type": "integer"]]],
            "required": ["cut"],
        ]
        for attempt in 0..<3 {
            if let r = try? await GeminiClient.completeWithUsage(prompt: prompt, system: system,
                                                                 model: GeminiClient.textModel,
                                                                 maxTokens: 4000, responseSchema: schema),
               let data = r.text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let cut = obj["cut"] as? [Int] { return cut }
                if let cut = obj["cut"] as? [Double] { return cut.map { Int($0) } }
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 600_000_000) }
        }
        return nil
    }

    /// Heuristic fallback (`--cut-heuristic`): mark consecutive duplicate words (same normalized text)
    /// except the LAST in each run, plus any word in `defaultFillers`.
    static func heuristicCutIndices(words: [TranscriptionWord], fillers: Set<String> = defaultFillers) -> [Int] {
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
        var cut: [Int] = []
        var i = 0
        while i < words.count {
            let n = norm(words[i].text)
            // A run of consecutive identical words: cut all but the last.
            var j = i
            while j + 1 < words.count, norm(words[j + 1].text) == n, !n.isEmpty { j += 1 }
            if j > i { cut.append(contentsOf: i..<j) }   // keep index j (the last), cut i..<j
            // Fillers (single words) — cut every occurrence not already covered.
            for k in i...j where fillers.contains(norm(words[k].text)) && !cut.contains(k) { cut.append(k) }
            i = j + 1
        }
        return cut.sorted()
    }
}
