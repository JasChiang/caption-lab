import Foundation

// Extracted verbatim from PalmierPro/Transcription/TranscriptCorrector.swift.
/// LLM cleanup of a raw transcript via direct Google Gemini (default gemini-flash-latest, any
/// Gemini model via `model`). Fixes spelling, brand/product names
/// (macOS, iPhone, Spotlight, AirDrop…), technical terms, and adds natural punctuation — which also
/// fixes weird line breaks, since CaptionBuilder splits on punctuation. Corrects each segment 1:1
/// (order + count preserved) so segment timing is kept. ORIGINAL per-word ASR timings are preserved
/// (karaoke needs them); the corrected text is propagated onto those words by matching CONTENT
/// characters (ignoring punctuation), so karaoke shows the cleaned text too. Bails safely on error.
enum TranscriptCorrector {
    /// Returns the corrected result and whether the LLM cleanup actually succeeded. `corrected == false`
    /// means every attempt failed and the caller is getting the RAW transcript back — surface that, don't
    /// pretend it was cleaned.
    static func correct(_ result: TranscriptionResult, model: String = GeminiClient.defaultModel,
                        glossary: [String] = [], contentSegments: [ContentSegment] = [], url: URL? = nil) async
        -> (result: TranscriptionResult, corrected: Bool, changes: [(from: String, to: String)]) {
        let segs = result.segments
        guard !segs.isEmpty else { return (result, true, []) }

        // A per-line REFERENCE from the content map — a second, video-grounded transcription of the same
        // audio. It lets correction fix soundalike errors that have NO textual cue (ASR 說得很很一樣 while the
        // map heard 說得很很遺憾): the recognizer's word is plausible on its own, so only a second opinion on
        // the audio can catch it.
        // Content-map timestamps are whole-second, model-estimated; widen the window so a reference that sits
        // just outside the segment's exact bounds is still matched.
        let mapSlop = 1.0
        func mapRef(_ seg: TranscriptionSegment) -> String? {
            let d = contentSegments
                .filter { $0.startSeconds < seg.end + mapSlop && $0.endSeconds > seg.start - mapSlop }
                .compactMap { $0.dialogue?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return d.isEmpty ? nil : d
        }
        let hasRefs = contentSegments.contains { ($0.dialogue?.isEmpty == false) }
        let numbered = segs.enumerated().map { i, s -> String in
            if let ref = mapRef(s) { return "\(i + 1). \(s.text)\n   REFERENCE: \(ref)" }
            return "\(i + 1). \(s.text)"
        }.joined(separator: "\n")
        // Project glossary: names/brands/jargon the recognizer mangles. Spell them EXACTLY as given and
        // prefer them over a same-sounding common word — the surest fix for proper nouns out of context.
        let terms = glossary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let glossaryRule = terms.isEmpty ? "" : """
         These names/terms appear in this project — spell them EXACTLY like this and prefer them over a \
        same-sounding ordinary word: \(terms.joined(separator: ", ")).
        """
        let referenceRule = !hasRefs ? "" : """
         Some lines carry a REFERENCE: an independent transcription of the SAME audio by a video-understanding \
        model. Treat it as a strong second opinion for soundalike errors that have no textual cue — when the \
        line and its REFERENCE disagree on a word and the REFERENCE reads more naturally in context, PREFER \
        the REFERENCE's word (e.g. a line reads 反應 where the REFERENCE clearly says 反映 → use 反映). But the REFERENCE is \
        NOT authoritative on disfluency: it routinely drops stutters and false starts, so never delete a \
        repeat to match it — keep every 去去去 / 進進 from the line. Swap a word only where line and REFERENCE \
        clearly describe the same syllable(s); never import extra wording the line does not support.
        """
        // Code-switching is a distinct failure mode for a single-locale (zh-TW) recognizer: it emits an
        // English word as ONE often-garbled Latin token (or drops it), and sometimes writes a spoken English
        // word as same-sounding Chinese characters (or the reverse). Call it out explicitly so the corrector
        // repairs the English rather than "fixing" it into plausible Chinese.
        let codeSwitchRule = """
         This speech mixes Mandarin and English (code-switching). Keep English words as ENGLISH and Chinese \
        as Chinese — never convert a spoken English word into same-sounding Chinese characters or vice versa \
        (e.g. don't turn a spoken "focus" into 佛克斯, or 六 into "leo"). Repair a mangled/garbled English \
        token back to its correct spelling and casing whenever context makes the intended word clear (the \
        recognizer emits English as a single, often-corrupted token), but only when you're confident of the \
        word — never invent English that wasn't said.
        """
        let system = """
        You clean up raw speech-to-text transcripts. For each numbered line, fix whatever the \
        recognizer got wrong, using context: characters or words it misheard — including \
        same-sounding (homophone / soundalike) substitutions in ANY language, which are especially common \
        in Chinese (e.g. 試用→使用, 帳號 not 賬號; English their/there) — plus misspellings, wrong word \
        boundaries, and brand / product / technical names (e.g. macOS, iPhone, AirDrop).\(codeSwitchRule)\(glossaryRule)\(referenceRule) Add natural punctuation, \
        using the language's OWN quotation marks (Chinese / Japanese 「…」 with 『…』 nested; never ASCII ' or "), \
        so a caption never strands a stray quote. Do NOT \
        paraphrase, rewrite, translate, summarize, reorder, or change the speaker's wording or meaning \
        — only correct recognition errors, so the words still line up with the audio. \
        CRITICAL: KEEP every repeated word, stutter, and false start EXACTLY as transcribed — 去去去去 stays \
        去去去去, 進進 stays 進進, "the the" stays "the the". These are NOT recognition errors; a SEPARATE edit \
        pass removes them from the audio, so the caption must still contain them or it won't match what's \
        spoken. Never collapse a stutter (去去去去進進行 must NOT become 進行). Keep the ORIGINAL \
        language. Also wrap any multi-character TERM that must never be split across two caption lines — a \
        technical term, proper noun, or fixed compound phrase (e.g. ⟦退化性關節炎⟧, ⟦iPhone⟧) — in ⟦ ⟧. \
        Wrap only genuine terms, never ordinary word sequences, and never change the characters inside. \
        Also insert the marker ¦ at natural ON-SCREEN CAPTION line breaks: after a clause or complete \
        thought so no caption line runs long, but NEVER mid-word, never right before a trailing particle \
        (的/了/嗎/呢), and never inside a ⟦ ⟧ term. Aim for readable chunks of roughly 6–16 characters; a \
        short line needs no ¦. The ¦ is a hint only — it is stripped and never counts as a character. \
        Return a JSON object {"lines":[…]} whose `lines` array has EXACTLY \(segs.count) items — one \
        corrected line per input line, same order. Do not split or merge lines; one input number → one array item.
        """
        let prompt = "Correct these \(segs.count) transcript lines (return exactly \(segs.count) items in `lines`):\n\(numbered)"

        // Force a structured array so the count can't drift: a disfluent run-on tempts the model to add
        // punctuation and split one segment across several free-text lines (which broke the old line parse
        // and dropped the whole transcript back to raw). A schema-bound array of exactly N items can't.
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["lines": ["type": "array", "items": ["type": "string"]]],
            "required": ["lines"],
        ]
        var marked: [String]?
        for attempt in 0..<3 {
            if let r = try? await GeminiClient.completeWithUsage(prompt: prompt, system: system, model: model,
                                                                 maxTokens: 8192, responseSchema: schema),
               let data = r.text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let lines = obj["lines"] as? [String], lines.count == segs.count {
                marked = lines.map { $0.trimmingCharacters(in: .whitespaces) }
                break
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 600_000_000) }
        }
        guard let marked else { return (result, false, []) }  // all attempts failed → raw, and say so

        // Pull the atomic terms out of the ⟦ ⟧ markers and the caption breaks out of the ¦ markers, then
        // strip both so segment text stays clean and keeps unit-for-unit alignment with the ASR words.
        var atomicTerms: Set<String> = []
        var segBreaks: [[Int]] = []
        let corrected = marked.map { line -> String in
            atomicTerms.formUnion(Self.extractTerms(line))
            let noTerms = line.replacingOccurrences(of: "\u{27E6}", with: "").replacingOccurrences(of: "\u{27E7}", with: "")
            let (clean, breaks) = extractCaptionBreaks(noTerms)
            segBreaks.append(breaks)
            return clean
        }

        let newSegs = zip(segs, corrected).enumerated().map { i, pair in
            TranscriptionSegment(text: pair.1, start: pair.0.start, end: pair.0.end, captionBreaks: segBreaks[i])
        }
        // With the source audio we can re-time words the recognizer never emitted (a recovered HDMI 2.1 / a
        // dropped syllable) onto energy peaks, so they land on the timeline instead of only in the segment text.
        let envelope: AudioEnvelope? = url == nil ? nil : (try? await AudioEnvelopeExtractor.extract(from: url!))
        let newWords = applyCorrectedText(to: result.words, segments: newSegs, corrected: corrected, envelope: envelope)
        // Surface WORD changes (homophone/typo fixes like 外麵→外面, 試用→使用) so the caller can show the
        // user what the LLM rewrote — punctuation-only differences are ignored.
        func content(_ s: String) -> String { String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)) }
        var changes: [(from: String, to: String)] = []
        for (o, c) in zip(segs, corrected) where content(o.text) != content(c) {
            changes.append((o.text.trimmingCharacters(in: .whitespaces), c.trimmingCharacters(in: .whitespaces)))
        }
        return (TranscriptionResult(text: corrected.joined(separator: " "), language: result.language,
                                    words: newWords, segments: newSegs, atomicTerms: Array(atomicTerms)), true, changes)
    }

    /// Splits the ¦ caption-break hints out of a corrected line: returns the clean text (markers removed)
    /// and the UNIT indices (CJK char / Latin run, punctuation ignored) AFTER which the caption should break.
    private static func extractCaptionBreaks(_ line: String) -> (text: String, breaks: [Int]) {
        var clean = "", breaks: [Int] = []
        for ch in line {
            if ch == "¦" {
                let u = CaptionBuilder.units(clean, keepPunctuation: false).count
                if u > 0, breaks.last != u { breaks.append(u) }
            } else {
                clean.append(ch)
            }
        }
        return (clean.trimmingCharacters(in: .whitespaces), breaks)
    }

    /// Multi-character substrings the LLM wrapped in ⟦ ⟧ on one line.
    private static func extractTerms(_ line: String) -> [String] {
        var out: [String] = [], current = ""
        var inside = false
        for ch in line {
            if ch == "\u{27E6}" { inside = true; current = "" }
            else if ch == "\u{27E7}" { if inside, current.count > 1 { out.append(current) }; inside = false }
            else if inside { current.append(ch) }
        }
        return out
    }

    /// Propagates the corrected segment text onto the per-word ASR timings that caption/karaoke rendering
    /// uses, keeping each word's real start/end. Matches by content UNITS (one CJK char, or a run of
    /// letters/digits, per unit; punctuation/space ignored). Per segment:
    ///  • exact 1:1 count → swap each word's text in place;
    ///  • drift (a stutter merged, a homophone with a different letter count) → align ASR↔corrected units by
    ///    LCS and swap only where the runs line up, leaving unmatched words as raw ASR;
    ///  • an INSERTED run the recognizer never emitted (Chinese speech that dropped an English "HDMI 2.1") →
    ///    with an `envelope` present, re-time those corrected units onto syllable energy peaks so they
    ///    actually appear on the timeline. Without an envelope the run is left as raw ASR, so this stays a
    ///    1:1, count-preserving writeback for the timing-preservation self-check.
    static func applyCorrectedText(
        to words: [TranscriptionWord], segments: [TranscriptionSegment], corrected: [String],
        envelope: AudioEnvelope? = nil
    ) -> [TranscriptionWord] {
        // Single pass over the time-ordered words: slice out each segment's run and rebuild it. Words that
        // fall in no segment (gaps between them) pass through unchanged.
        var out: [TranscriptionWord] = []
        var wi = 0
        for (i, s) in segments.enumerated() where i < corrected.count {
            var seg: [TranscriptionWord] = []
            while wi < words.count {
                let w = words[wi]
                guard let st = w.start, let en = w.end else { out.append(w); wi += 1; continue }
                let mid = (st + en) / 2
                if mid < s.start { out.append(w); wi += 1; continue }  // before this segment
                if mid >= s.end { break }                             // past this segment
                seg.append(w); wi += 1
            }
            let units = CaptionBuilder.units(corrected[i], keepPunctuation: false)
            out.append(contentsOf: rebuildSegment(seg, units: units, envelope: envelope))
        }
        while wi < words.count { out.append(words[wi]); wi += 1 }
        return out
    }

    /// Rebuilds one segment's words so their text matches `units`, keeping ASR timing where the two line up
    /// and re-timing an inserted/dropped run on energy peaks when an `envelope` is given.
    private static func rebuildSegment(_ seg: [TranscriptionWord], units: [String],
                                       envelope: AudioEnvelope?) -> [TranscriptionWord] {
        guard !units.isEmpty else { return seg }   // nothing corrected → keep as-is
        guard !seg.isEmpty else { return seg }     // no timing to attach to
        if units.count == seg.count {
            return zip(seg, units).map { TranscriptionWord(text: $1, start: $0.start, end: $0.end) }
        }
        var result: [TranscriptionWord] = []
        for block in alignBlocks(a: seg.map(\.text), b: units) {
            let aw = Array(seg[block.a]), bu = Array(units[block.b])
            if bu.isEmpty {
                result.append(contentsOf: aw)                                    // deletion: keep ASR words
            } else if aw.count == bu.count {
                result.append(contentsOf: zip(aw, bu).map { TranscriptionWord(text: $1, start: $0.start, end: $0.end) })
            } else if let env = envelope, let s = aw.first?.start, let e = aw.last?.end {
                // Slice to the span: placeOnEnergyPeaks treats sample 0 as `start`, so the full-clip envelope
                // correct() passes would otherwise pick peaks from the wrong window (fixed 2026-07-02).
                result.append(contentsOf: CaptionPipeline.placeOnEnergyPeaks(bu, start: s, end: e, envelope: env.slice(s...e)))
            } else {
                result.append(contentsOf: aw)                                    // no envelope → leave raw ASR
            }
        }
        return result
    }

    private struct AlignBlock { let a: Range<Int>; let b: Range<Int> }

    /// Minimal LCS diff opcodes over units: each matched position is a singleton equal block; the differing
    /// run between two matches is one block (which rebuildSegment classifies as swap / insert / delete).
    private static func alignBlocks(a: [String], b: [String]) -> [AlignBlock] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [AlignBlock(a: 0..<n, b: 0..<m)] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var blocks: [AlignBlock] = []
        var i = 0, j = 0, pa = 0, pb = 0
        func emitGap(_ ae: Int, _ be: Int) { if ae > pa || be > pb { blocks.append(AlignBlock(a: pa..<ae, b: pb..<be)) } }
        while i < n, j < m {
            if a[i] == b[j] {
                emitGap(i, j)
                blocks.append(AlignBlock(a: i..<(i + 1), b: j..<(j + 1)))
                i += 1; j += 1; pa = i; pb = j
            } else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        emitGap(n, m)
        return blocks
    }

}
