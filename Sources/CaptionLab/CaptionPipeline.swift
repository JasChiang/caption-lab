import AVFoundation
import Foundation

// De-tangled from EditorViewModel extensions in the main app:
//   - contentMapGlossaryTerms / extractContentTerms  (EditorViewModel+Captions.swift)
//   - retranscribeSuspectSpans + its helpers          (EditorViewModel+Retranscribe.swift)
//
// The algorithms are unchanged. Only the @MainActor view-model plumbing is removed:
//   * `mediaAssets` / `asset.contentSegments` / `mediaResolver.resolveURL(for:)` → explicit params
//     (this CLI processes ONE media file, so the original per-`ref` loop collapses to a single call).
//   * `contentMapTermsCache` / `retranscribeSpanCache` → dropped / passed as inout.
//   * `GeminiKeychain.hasKey` → $GEMINI_API_KEY presence check.
//   * `captionRetranscribes` (view-model state the GUI reads) → returned as a value.
enum CaptionPipeline {

    private static var hasGeminiKey: Bool {
        let k = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
        return k?.isEmpty == false
    }

    // NOTE: the separate glossary-harvest call is GONE — the content map's own video call now emits a
    // trailing `TERMS:` line (see MediaDescriber), so term extraction rides the pass that actually watched
    // the clip (best context, incl. on-screen text) instead of a second flash-lite call over its dialogue.

    // MARK: - Retranscribe suspect spans (from EditorViewModel+Retranscribe.swift)

    struct Retranscribe { let from: String; let to: String; let t: String }

    /// OPT-IN repair for the ASR dropped/merged-syllable class (spoken 正念減壓 recognized as 整年檢壓): the
    /// count-locked text corrector can swap characters but can't reinsert a syllable the recognizer never
    /// emitted, while the deep content map's near-verbatim dialogue DID capture it. Compare each ASR segment
    /// to the map dialogue in the same time window; where they disagree a lot, re-transcribe just that audio
    /// span with Gemini audio and splice its verbatim text back, re-timing that span's words on
    /// syllable-nucleus ENERGY PEAKS. Conservative: a content map + Gemini key are required, the retranscribe
    /// is only accepted if it agrees with the map BETTER than the ASR did, and the costly Gemini call is
    /// cached per span.
    /// Returns the (possibly) repaired result and the list of spans it replaced. Detection threshold is
    /// untuned — gated behind the caller's opt-in.
    static func retranscribeSuspectSpans(
        result res: TranscriptionResult, url: URL, contentSegments mapSegs: [ContentSegment],
        spanCache retranscribeSpanCache: inout [String: String],
        conditioning: AudioConditioning = AudioConditioning(),
        model: String = GeminiClient.defaultModel,
        refiner: RefineBackend = .gemini
    ) async -> (result: TranscriptionResult, retranscribes: [Retranscribe]) {
        var captionRetranscribes: [Retranscribe] = []
        // The suspect-span DETECTION still needs the content map + a Gemini key (the map is the reference the
        // whole stage is gated on). The re-LISTEN, though, can be offline: honor `.localASR` only when the
        // sidecar is actually set up, else fall back to the cloud path so the stage still runs.
        let useLocalASR = (refiner == .localASR) && LocalASR.isAvailable()
        guard hasGeminiKey else { return (res, captionRetranscribes) }
        let ref = url.path
        guard !mapSegs.isEmpty, !res.segments.isEmpty else { return (res, captionRetranscribes) }

        struct Suspect { let seg: TranscriptionSegment; let hint: String }
        var suspects: [Suspect] = []
        for seg in res.segments {
            let mapText = mapDialogue(overlapping: seg.start...seg.end, in: mapSegs)
            guard contentChars(mapText).count >= 4, contentChars(seg.text).count >= 2 else { continue }
            if charOverlap(seg.text, mapText) < 0.5 { suspects.append(Suspect(seg: seg, hint: mapText)) }
        }
        guard !suspects.isEmpty else { return (res, captionRetranscribes) }

        var words = res.words
        var segments = res.segments
        for s in suspects {
            // Cache the costly Gemini call per source span, so a rebuild reuses the same verbatim text.
            let spanKey = "\(ref)|\(Int((s.seg.start * 10).rounded()))|\(Int((s.seg.end * 10).rounded()))"
            let clean: String
            if let cached = retranscribeSpanCache[spanKey] {
                clean = cached
            } else if useLocalASR {
                // OFFLINE re-listen: the local Whisper sidecar exports + transcribes the span itself (no m4a
                // upload, no API cost). Same verbatim contract; timing is still assigned on energy peaks below.
                guard let verbatim = try? await LocalASR.transcribeSpan(
                    url: url, start: s.seg.start, end: s.seg.end, language: res.language, biasHint: s.hint) else { continue }
                clean = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
                retranscribeSpanCache[spanKey] = clean
            } else {
                guard let span = await extractSpanM4A(from: url, start: s.seg.start, end: s.seg.end) else { continue }
                // Condition the suspect span before re-transcribing: normalize (quiet audio) and force a
                // slow-down (this span is already flagged as garbled — likely a fast run). We only keep the
                // TEXT; the span's word timings are placed on the ORIGINAL-clock energy peaks below, so the
                // slow-down needs no time mapping. Falls back to the raw m4a if conditioning fails.
                var spanURL = span
                var spanMIME = "audio/mp4"
                if !conditioning.isNoop,
                   let cond = await AudioConditioner.condition(url: span, options: conditioning,
                                                               forceStretch: conditioning.slowFastSpeech, container: .wav) {
                    try? FileManager.default.removeItem(at: span)
                    spanURL = cond.url
                    spanMIME = AudioConditioner.Container.wav.mimeType
                }
                // The re-listen uses the PIPELINE's model tier, not the cheap text tier: this is the hardest
                // listening job in the app (a span the on-device recognizer already garbled), so sending it
                // to flash-lite while the content map got flash was exactly backwards.
                guard let verbatim = try? await GeminiClient.transcribeAudio(fileURL: spanURL, mimeType: spanMIME, biasHint: s.hint, model: model) else {
                    try? FileManager.default.removeItem(at: spanURL); continue
                }
                try? FileManager.default.removeItem(at: spanURL)
                clean = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
                retranscribeSpanCache[spanKey] = clean
            }
            guard contentChars(clean).count >= 2 else { continue }
            // Accept only if the retranscribe matches the map BETTER than the ASR did — else we'd be
            // trading one recognizer error for a different model's error.
            guard charOverlap(clean, s.hint) > charOverlap(s.seg.text, s.hint) else { continue }

            let units = CaptionBuilder.units(clean, keepPunctuation: false)
            guard !units.isEmpty else { continue }
            // Place the units on syllable-nucleus ENERGY PEAKS within the span (CJK: 1 char ≈ 1 peak).
            let envelope = try? await AudioEnvelopeExtractor.extract(from: url, range: s.seg.start...s.seg.end)
            let fresh = placeOnEnergyPeaks(units, start: s.seg.start, end: s.seg.end, envelope: envelope)
            words.removeAll { w in
                guard let st = w.start, let en = w.end else { return false }
                let mid = (st + en) / 2
                return mid >= s.seg.start && mid < s.seg.end
            }
            words.append(contentsOf: fresh)
            segments = segments.map {
                $0.start == s.seg.start && $0.end == s.seg.end
                    ? TranscriptionSegment(text: clean, start: $0.start, end: $0.end) : $0
            }
            let sec = Int(s.seg.start)
            captionRetranscribes.append(Retranscribe(from: s.seg.text.trimmingCharacters(in: .whitespaces),
                                                     to: clean, t: String(format: "%d:%02d", sec / 60, sec % 60)))
        }
        words.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        let out = TranscriptionResult(text: segments.map(\.text).joined(separator: " "),
                                      language: res.language, words: words, segments: segments,
                                      atomicTerms: res.atomicTerms)
        return (out, captionRetranscribes)
    }

    /// Place caption UNITS on syllable-nucleus energy peaks within [start,end]. For syllabic scripts (CJK /
    /// kana / Hangul) one character ≈ one energy peak, so the N strongest peaks (in time order) give each
    /// unit its real spoken moment — far better than an even spread for a re-transcribed span. Falls back to
    /// even distribution when the text is NOT syllabic, the envelope is missing, or it can't resolve at least
    /// N peaks. `envelope` samples are RMS at `hopSeconds`, starting at `start`.
    static func placeOnEnergyPeaks(_ units: [String], start: Double, end: Double, envelope: AudioEnvelope?) -> [TranscriptionWord] {
        let n = units.count
        let dur = max(end - start, 0.001)
        func even() -> [TranscriptionWord] {
            units.enumerated().map { i, u in
                TranscriptionWord(text: u, start: start + dur * Double(i) / Double(n), end: start + dur * Double(i + 1) / Double(n))
            }
        }
        guard units.filter({ isSyllabicUnit($0) }).count * 2 >= n,   // majority syllabic
              let env = envelope, env.samples.count > 2, let maxE = env.samples.max(), maxE > 0 else { return even() }
        let floor = maxE * 0.15
        var peaks: [(e: Float, t: Double)] = []
        let s = env.samples
        for i in 1..<(s.count - 1) where s[i] >= s[i - 1] && s[i] > s[i + 1] && s[i] >= floor {
            peaks.append((s[i], start + Double(i) * env.hopSeconds))
        }
        guard peaks.count >= n else { return even() }
        let chosen = peaks.sorted { $0.e > $1.e }.prefix(n).map(\.t).sorted()
        return units.enumerated().map { i, u in
            let lo = i == 0 ? start : (chosen[i - 1] + chosen[i]) / 2
            let hi = i == n - 1 ? end : (chosen[i] + chosen[i + 1]) / 2
            return TranscriptionWord(text: u, start: max(start, lo), end: min(end, max(lo + 0.02, hi)))
        }
    }

    /// A single character in a SYLLABIC script (CJK / kana / Hangul), where one glyph ≈ one spoken syllable
    /// ≈ one energy peak. Latin word/number units fail this (a word spans several peaks), so they keep an
    /// even spread.
    private static func isSyllabicUnit(_ u: String) -> Bool {
        guard u.count == 1, let v = u.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)   // CJK + ext A
            || (0x3040...0x30FF).contains(v)                                    // hiragana / katakana
            || (0xAC00...0xD7A3).contains(v)                                    // Hangul syllables
    }

    /// Content-map segment timestamps are whole-second, model-ESTIMATED (MediaDescriber parses MM:SS), so a
    /// real overlap can sit just outside an exact window. Grow both windows by this slop before testing.
    private static let mapWindowSlop: Double = 1.0

    /// Concatenated content-map dialogue overlapping a source-time window (widened by `mapWindowSlop`).
    private static func mapDialogue(overlapping range: ClosedRange<Double>, in segs: [ContentSegment]) -> String {
        segs.filter { $0.startSeconds < range.upperBound + mapWindowSlop && $0.endSeconds > range.lowerBound - mapWindowSlop }
            .compactMap { $0.dialogue?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Content characters (alphanumeric incl. CJK), lowercased, punctuation/space stripped.
    private static func contentChars(_ s: String) -> [Character] {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)
    }

    /// Fraction of `a`'s content characters that also appear in `b` (multiset). Language-general — works
    /// CJK char-by-char and for Latin — and near 1.0 when the two say the same thing.
    private static func charOverlap(_ a: String, _ b: String) -> Double {
        let ca = contentChars(a)
        guard !ca.isEmpty else { return 1 }
        var bag: [Character: Int] = [:]
        for c in contentChars(b) { bag[c, default: 0] += 1 }
        var hit = 0
        for c in ca where (bag[c] ?? 0) > 0 { bag[c]! -= 1; hit += 1 }
        return Double(hit) / Double(ca.count)
    }

    /// Export a source-time span to a temp m4a (AAC) for an external audio model. Caller deletes it.
    private static func extractSpanM4A(from url: URL, start: Double, end: Double) async -> URL? {
        guard end > start else { return nil }
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("retr-\(UUID().uuidString.prefix(8)).m4a")
        try? FileManager.default.removeItem(at: out)
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        do { try await session.export(to: out, as: .m4a) } catch { return nil }
        return out
    }
}
