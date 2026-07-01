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
                        glossary: [String] = [], contentSegments: [ContentSegment] = []) async
        -> (result: TranscriptionResult, corrected: Bool, changes: [(from: String, to: String)]) {
        let segs = result.segments
        guard !segs.isEmpty else { return (result, true, []) }

        // A per-line REFERENCE from the content map — a second, video-grounded transcription of the same
        // audio. It lets correction fix soundalike errors that have NO textual cue (ASR 說得很很一樣 while the
        // map heard 說得很很遺憾): the recognizer's word is plausible on its own, so only a second opinion on
        // the audio can catch it.
        func mapRef(_ seg: TranscriptionSegment) -> String? {
            let d = contentSegments
                .filter { $0.startSeconds < seg.end && $0.endSeconds > seg.start }
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
        let system = """
        You clean up raw speech-to-text transcripts. For each numbered line, fix whatever the \
        recognizer got wrong, using context: characters or words it misheard — including \
        same-sounding (homophone / soundalike) substitutions in ANY language, which are especially common \
        in Chinese (e.g. 試用→使用, 帳號 not 賬號; English their/there) — plus misspellings, wrong word \
        boundaries, and brand / product / technical names (e.g. macOS, iPhone, AirDrop).\(glossaryRule)\(referenceRule) Add natural punctuation, \
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

        // Pull the atomic terms out of the ⟦ ⟧ markers, then strip the markers so segment text stays clean
        // (and keeps unit-for-unit alignment with the ASR words — the markers are dropped by units() anyway).
        var atomicTerms: Set<String> = []
        let corrected = marked.map { line -> String in
            atomicTerms.formUnion(Self.extractTerms(line))
            return line.replacingOccurrences(of: "\u{27E6}", with: "").replacingOccurrences(of: "\u{27E7}", with: "")
        }

        let newSegs = zip(segs, corrected).map { TranscriptionSegment(text: $1, start: $0.start, end: $0.end) }
        let newWords = applyCorrectedText(to: result.words, segments: newSegs, corrected: corrected)
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

    /// Propagates corrected segment text onto the per-word ASR timings (which karaoke renders), keeping
    /// each word's real start/end. Matches by content UNITS — one CJK character per unit, a run of
    /// letters/digits (a Latin word / number) per unit, punctuation + whitespace ignored. When a
    /// segment's corrected unit count equals its ASR word count, each word's text is swapped for the
    /// corrected unit. Unit matching survives BOTH the LLM adding punctuation AND brand-name fixes that
    /// change letter count (Michos→macOS is still one unit→one unit), which a character-count match
    /// could not. Words in a segment that doesn't align are left untouched.
    static func applyCorrectedText(
        to words: [TranscriptionWord], segments: [TranscriptionSegment], corrected: [String]
    ) -> [TranscriptionWord] {
        var newWords = words
        for (i, s) in segments.enumerated() where i < corrected.count {
            let wordIdxs = newWords.indices.filter { w in
                guard let st = newWords[w].start, let en = newWords[w].end else { return false }
                let mid = (st + en) / 2
                return mid >= s.start && mid < s.end
            }
            let units = CaptionBuilder.units(corrected[i], keepPunctuation: false)
            guard !units.isEmpty, !wordIdxs.isEmpty else { continue }
            // Fast path: whole segment lines up 1:1 → swap every word (cheapest, unchanged behavior).
            if units.count == wordIdxs.count {
                for (j, wi) in wordIdxs.enumerated() {
                    newWords[wi] = TranscriptionWord(text: units[j], start: newWords[wi].start, end: newWords[wi].end)
                }
                continue
            }
            // Granular path: the segment's unit count drifted (a stutter merged, a syllable added). Instead of
            // skipping the WHOLE segment — which threw away easy same-position fixes like 整年檢壓→正念減壓 just
            // because one unit elsewhere didn't line up — align ASR units to corrected units by LCS and swap
            // only where the mapping is unambiguous (matched anchors + equal-length substitution runs between
            // them). Insertions/deletions are left as raw ASR: this stage never re-times, so a genuinely added
            // syllable is left for the energy-peak re-timing in the retranscribe stage.
            let asrUnits = wordIdxs.map { newWords[$0].text }
            for (aj, text) in alignedPositionalSwaps(a: asrUnits, b: units) {
                let wi = wordIdxs[aj]
                newWords[wi] = TranscriptionWord(text: text, start: newWords[wi].start, end: newWords[wi].end)
            }
        }
        return newWords
    }

    /// Aligns ASR units `a` to corrected units `b` and returns, per index of `a`, the corrected text it
    /// should take — but ONLY where the mapping is safe: LCS-matched positions, plus runs between matches
    /// whose ASR and corrected lengths are equal (a pure substitution like 金→親 / 賭→讀 maps 1:1, keeping
    /// that word's original timing). Unequal runs (an inserted or dropped syllable) are omitted, so those
    /// ASR words keep their own text rather than smearing corrected text across mistimed slots.
    static func alignedPositionalSwaps(a: [String], b: [String]) -> [Int: String] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [:] }
        // LCS length table (suffix DP).
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        // Backtrack the matched (ai, bj) anchor pairs.
        var matches: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { matches.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        var out: [Int: String] = [:]
        var prevA = -1, prevB = -1
        func fillEqualGap(aEnd: Int, bEnd: Int) {
            let aLen = aEnd - (prevA + 1), bLen = bEnd - (prevB + 1)
            guard aLen > 0, aLen == bLen else { return }
            for k in 0..<aLen { out[prevA + 1 + k] = b[prevB + 1 + k] }
        }
        for (ai, bj) in matches {
            fillEqualGap(aEnd: ai, bEnd: bj)   // equal-length substitution run before this anchor
            out[ai] = b[bj]                    // the matched unit (identical text; keeps timing)
            prevA = ai; prevB = bj
        }
        fillEqualGap(aEnd: n, bEnd: m)         // trailing run after the last anchor
        return out
    }

}
