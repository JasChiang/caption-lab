import Foundation

// Manual caption editing: edit a line's text in a multi-line field (Enter = split into separate caption
// lines, PalmierPro-style), or merge a line with the next one. Edits mutate the clip's WORKING result
// (afterRetranscribe) — the same artifact the overlay renders from — so player captions and the editor
// always agree. Word timings are preserved wherever the text still matches (LCS) and re-timed on syllable
// energy peaks where it changed, via the same applyCorrectedText path the correction stage uses.
// Re-running the pipeline overwrites manual edits.
extension PipelineViewModel {

    struct CaptionChunk: Identifiable, Equatable {
        let id: Int                      // sequential across the clip; adjacent ids = adjacent lines
        let segIndex: Int
        let unitLo: Int, unitHi: Int     // unit range within the segment (CJK char / Latin run)
        let start: Double, end: Double   // clip-LOCAL seconds
        let text: String
    }

    /// The working result manual edits apply to (what captions render from).
    func editableResult(for clip: ClipModel) -> TranscriptionResult? {
        clip.afterRetranscribe ?? clip.corrected
    }

    /// Caption lines for ONE clip with their segment/unit provenance — the single source of chunking for
    /// both the on-video overlay (`rebuildCaptionCache`) and the editor panel.
    func captionChunks(for result: TranscriptionResult) -> [CaptionChunk] {
        var chunks: [CaptionChunk] = []
        let words = result.words
        for (si, seg) in result.segments.enumerated() {
            let segWords = words.filter {
                guard let s = $0.start, let e = $0.end else { return false }
                let m = (s + e) / 2
                return m >= seg.start && m < seg.end
            }
            guard !segWords.isEmpty else { continue }
            let du = CaptionBuilder.units(seg.text, keepPunctuation: true)
            guard !du.isEmpty else { continue }
            // Inter-word silence at each unit boundary (positional unit≈word mapping) so a forced break can
            // land on a real breath — the main lever for fast speech where ¦ hints are sparse.
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
                        chunks.append(CaptionChunk(id: chunks.count, segIndex: si,
                                                   unitLo: s, unitHi: min(e, du.count),
                                                   start: a, end: b, text: text))
                    }
                }
                s = e
            }
        }
        return chunks
    }

    func seek(to chunk: CaptionChunk, in clip: ClipModel) {
        guard let idx = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        seekRaw(to: rawOffset(of: idx) + chunk.start)
    }

    /// Apply an edited line. NEWLINES in `raw` split the text into separate caption lines (the editor field
    /// maps Enter to a split, PalmierPro-style); ¦ / | are accepted as split markers too.
    func applyCaptionEdit(clip: ClipModel, chunkID: Int, newText raw: String) {
        guard let result = editableResult(for: clip) else { return }
        let chunks = captionChunks(for: result)
        guard let chunk = chunks.first(where: { $0.id == chunkID }), chunk.segIndex < result.segments.count else { return }

        // Newline / ¦ / | → interior break positions (in punctuation-ignored unit space, same as captionBreaks).
        var clean = ""
        var innerBreaks: [Int] = []
        for ch in raw {
            if ch == "\n" || ch == "\u{00A6}" || ch == "|" {
                let u = CaptionBuilder.units(clean, keepPunctuation: false).count
                if u > 0, innerBreaks.last != u { innerBreaks.append(u) }
            } else {
                clean.append(ch)
            }
        }
        clean = clean.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }        // deleting a whole line is out of scope — edit it instead

        var segs = result.segments
        let seg = segs[chunk.segIndex]
        let du = CaptionBuilder.units(seg.text, keepPunctuation: true)
        guard chunk.unitLo <= chunk.unitHi, chunk.unitHi <= du.count else { return }
        let newCount = CaptionBuilder.units(clean, keepPunctuation: false).count
        let delta = newCount - (chunk.unitHi - chunk.unitLo)
        let total = du.count + delta

        // Splice the segment text by unit boundaries (punctuation stays attached to its unit).
        let newSegText = CaptionBuilder.joinUnits(Array(du[0..<chunk.unitLo]) + [clean] + Array(du[chunk.unitHi...]))

        // Shift breaks outside the edited span; replace the ones inside with the edit's own splits.
        var breaks: [Int] = seg.captionBreaks.compactMap { b in
            if b <= chunk.unitLo { return b }
            if b >= chunk.unitHi { return b + delta }
            return nil
        }
        breaks += innerBreaks.map { chunk.unitLo + $0 }
        breaks = Array(Set(breaks.filter { $0 > 0 && $0 < total })).sorted()
        // Sentinel: keep the LLM-break path authoritative even with no interior breaks left — a break at
        // `total` is ignored by captionStops' filter but keeps the list non-empty, so the punctuation
        // fallback can't re-split a line the user deliberately merged/unified.
        if breaks.isEmpty { breaks = [total] }
        segs[chunk.segIndex] = TranscriptionSegment(text: newSegText, start: seg.start, end: seg.end, captionBreaks: breaks)

        // Re-propagate text onto word timings: unchanged text keeps its timing (LCS), changed runs re-time
        // on syllable energy peaks within their span.
        let words = TranscriptCorrector.applyCorrectedText(to: result.words, segments: segs,
                                                           corrected: segs.map(\.text), envelope: clip.envelope)
        commit(segs, words: words, from: result, to: clip)
    }

    /// Merge a caption line with the NEXT one (removes the break between them; across a segment boundary it
    /// merges the two segments — words keep their timings either way).
    func mergeCaptionWithNext(clip: ClipModel, chunkID: Int) {
        guard let result = editableResult(for: clip) else { return }
        let chunks = captionChunks(for: result)
        guard let a = chunks.first(where: { $0.id == chunkID }),
              let b = chunks.first(where: { $0.id == chunkID + 1 }) else { return }
        var segs = result.segments

        if a.segIndex == b.segIndex {
            let seg = segs[a.segIndex]
            let total = CaptionBuilder.units(seg.text, keepPunctuation: false).count
            var breaks = seg.captionBreaks.filter { $0 != a.unitHi }
            if breaks.filter({ $0 > 0 && $0 < total }).isEmpty { breaks = [total] }   // sentinel (see above)
            segs[a.segIndex] = TranscriptionSegment(text: seg.text, start: seg.start, end: seg.end, captionBreaks: breaks)
        } else {
            guard b.segIndex == a.segIndex + 1 else { return }
            let s1 = segs[a.segIndex], s2 = segs[b.segIndex]
            let c1 = CaptionBuilder.units(s1.text, keepPunctuation: false).count
            let total = c1 + CaptionBuilder.units(s2.text, keepPunctuation: false).count
            // Junction gets NO break — that's exactly what we're merging away.
            var breaks = s1.captionBreaks.filter { $0 > 0 && $0 < c1 }
                + s2.captionBreaks.map { $0 + c1 }.filter { $0 > c1 && $0 < total }
            if breaks.isEmpty { breaks = [total] }
            segs[a.segIndex] = TranscriptionSegment(text: CaptionBuilder.joinUnits([s1.text, s2.text]),
                                                    start: s1.start, end: s2.end, captionBreaks: breaks.sorted())
            segs.remove(at: b.segIndex)
        }
        commit(segs, words: result.words, from: result, to: clip)
    }

    private func commit(_ segs: [TranscriptionSegment], words: [TranscriptionWord],
                        from old: TranscriptionResult, to clip: ClipModel) {
        clip.afterRetranscribe = TranscriptionResult(
            text: segs.map(\.text).joined(separator: " "), language: old.language,
            words: words, segments: segs, atomicTerms: old.atomicTerms, conditionReport: old.conditionReport)
        rebuildCaptionCache()
    }
}
