import Foundation

// Extracted verbatim from PalmierPro/Transcription/Transcription.swift.
struct TranscriptionWord: Sendable, Codable {
    let text: String
    let start: Double?
    let end: Double?
}

/// One natural utterance the transcriber endpointed on its own (pause/sentence
/// boundary). `text` carries the model's punctuation and casing.
struct TranscriptionSegment: Sendable, Codable {
    let text: String
    let start: Double
    let end: Double
    /// Unit indices (CJK char / Latin run, punctuation ignored) AFTER which the on-video caption should
    /// break, suggested by the correction LLM in the same call (semantic, style-agnostic breaks that a
    /// punctuation/pause heuristic can't match). Empty when unavailable — callers fall back to punctuation.
    var captionBreaks: [Int] = []
    /// Unit indices the corrector marked as REMOVABLE DISFLUENCIES (⟨⟩: stutter repeats, false starts,
    /// fillers) in the SAME judgment pass that corrected and broke the text — one semantic pass, so the cut
    /// list can never disagree with the caption. The words stay in the text (count-lock intact); stage 6
    /// removes them from the AUDIO mechanically.
    var cutUnits: [Int] = []
}

struct TranscriptionResult: Sendable, Codable {
    let text: String
    let language: String?
    let words: [TranscriptionWord]
    let segments: [TranscriptionSegment]
    /// Multi-character terms the correction LLM marked atomic (a caption line must never split inside one,
    /// e.g. 退化性關節炎). Rides the corrected result; excluded from Codable so cached transcripts — which
    /// never carry it — stay decodable.
    var atomicTerms: [String] = []
    /// What pre-ASR conditioning did to the audio (normalize / slow-down), for the GUI/CLI to surface. Not
    /// Codable — a transient annotation on the live result, never persisted.
    var conditionReport: AudioConditionReport? = nil

    enum CodingKeys: String, CodingKey { case text, language, words, segments }

    /// Shifts all timestamps back into source time after transcribing an extracted range
    func offsetting(by offset: Double) -> TranscriptionResult {
        guard offset != 0 else { return self }
        return TranscriptionResult(
            text: text,
            language: language,
            words: words.map {
                TranscriptionWord(text: $0.text, start: $0.start.map { $0 + offset }, end: $0.end.map { $0 + offset })
            },
            segments: segments.map {
                TranscriptionSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset,
                                     captionBreaks: $0.captionBreaks, cutUnits: $0.cutUnits)
            },
            atomicTerms: atomicTerms,
            conditionReport: conditionReport
        )
    }
}

enum TranscriptionError: LocalizedError {
    case unsupportedLocale(String)
    case modelInstallFailed(String)
    case decodeFailed
    case audioExtractionFailed(String)
    case analysisFailed(String)
    case speechServiceTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id):
            return "On-device transcription is not available for \(id)."
        case .modelInstallFailed(let reason):
            return "Could not install the on-device speech model: \(reason)"
        case .decodeFailed:
            return "Could not parse transcription result."
        case .audioExtractionFailed(let reason):
            return "Audio extraction failed: \(reason)"
        case .analysisFailed(let reason):
            return "Transcription failed: \(reason)"
        case .speechServiceTimedOut(let operation):
            return "\(operation) did not respond. The on-device speech service may be busy — try again."
        }
    }
}

/// One timestamped moment in an asset: source-time range + what's visible (and any key dialogue/narration).
/// Extracted from PalmierPro/Models/MediaManifest.swift (only this type — not the wider manifest graph).
struct ContentSegment: Codable, Sendable, Equatable {
    var startSeconds: Double
    var endSeconds: Double
    var visual: String
    var dialogue: String?
    /// Who is speaking in this segment — a short, consistent label per person across the clip (主持人 /
    /// 來賓 / a name), or nil when there's no speech. Gemini already distinguishes speakers when it writes
    /// the content map; this captures that as structured data instead of burying it in `visual`. Optional
    /// with a default so older dumps (no speaker) still decode and existing constructions still compile.
    var speaker: String? = nil
}
