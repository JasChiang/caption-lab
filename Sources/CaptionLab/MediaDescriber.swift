import Foundation

// Extracted from PalmierPro/Search/MediaDescriber.swift — ONLY the deep-content-map path
// (describeVideoContentMap + parseContentMap + secondsFromMMSS). The frame-sampling / on-device
// Vision / one-line VLM describe paths are dropped (they pull in CoreImage/Vision/FrameSampler and
// aren't part of the caption-correction pipeline).
enum MediaDescriber {
    /// Deep video understanding: uploads the whole clip to Gemini and asks a video-capable VLM (which sees
    /// frames AND audio) for a TIMESTAMPED content map — what's on screen + what's said, per shot. Returns
    /// the parsed segments + a one-line summary.
    static func describeVideoContentMap(
        url: URL, language: String, model: String = GeminiClient.defaultModel
    ) async throws -> (label: String?, segments: [ContentSegment], usage: GeminiClient.Usage) {
        let prompt = """
        Watch this entire video and break it into its distinct shots/segments in order. For EACH segment \
        output ONE line EXACTLY as:
        [MM:SS-MM:SS] <speaker> | <visual> | <dialogue>
        where <speaker> identifies WHO is speaking in that segment — use a SHORT, CONSISTENT label for each \
        person across the WHOLE video (e.g. 主持人, 來賓, 旁白, or their name if it is stated), and reuse the \
        exact same label every time that person speaks; use - if no one is speaking. <visual> is a concrete \
        description in \(language) (subjects, action, setting). <dialogue> is the key spoken words / on-screen \
        narration in that segment in \(language), or - if none. \
        Cover the WHOLE video. After all segments, output one final line:
        SUMMARY: <one sentence describing the whole clip in \(language)>
        No preamble, no markdown, no extra lines.
        """
        // A long clip yields many segment lines plus the trailing SUMMARY; a tight cap truncates it.
        // Gemini File API uploads the local clip directly (no fal CDN hop); low-res keeps it cheap.
        let r = try await GeminiClient.describeVideo(fileURL: url, prompt: prompt, model: model, maxTokens: 8000, lowRes: true)
        let parsed = parseContentMap(r.text)
        return (parsed.label, parsed.segments, r.usage)
    }

    /// Parse the `[MM:SS-MM:SS] visual | dialogue` lines + a trailing `SUMMARY:` line.
    static func parseContentMap(_ text: String) -> (label: String?, segments: [ContentSegment]) {
        var segments: [ContentSegment] = []
        var label: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.uppercased().hasPrefix("SUMMARY:") {
                label = line.dropFirst("SUMMARY:".count).trimmingCharacters(in: .whitespaces); continue
            }
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let range = String(line[line.index(after: line.startIndex)..<close])  // MM:SS-MM:SS
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let parts = range.split(separator: "-", maxSplits: 1).map { secondsFromMMSS(String($0)) }
            guard parts.count == 2, let s = parts[0], let e = parts[1] else { continue }
            // New format is `<speaker> | <visual> | <dialogue>`; tolerate the old 2-field `<visual> | <dialogue>`
            // (speaker nil) so a model that ignores the speaker field still parses.
            let halves = rest.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            func clean(_ s: String?) -> String? { (s == nil || s == "-" || s!.isEmpty) ? nil : s }
            let speaker: String?, visual: String, dialogue: String?
            if halves.count >= 3 {
                speaker = clean(halves[0]); visual = halves[1]; dialogue = clean(halves[2])
            } else {
                speaker = nil; visual = halves.first ?? ""; dialogue = clean(halves.count > 1 ? halves[1] : nil)
            }
            if !visual.isEmpty {
                segments.append(ContentSegment(startSeconds: s, endSeconds: max(e, s), visual: visual,
                                               dialogue: dialogue, speaker: speaker))
            }
        }
        return (label, segments)
    }

    private static func secondsFromMMSS(_ s: String) -> Double? {
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        if p.count == 2, let m = Double(p[0]), let sec = Double(p[1]) { return m * 60 + sec }
        if p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) { return h * 3600 + m * 60 + sec }
        return Double(s.trimmingCharacters(in: .whitespaces))
    }
}
