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
                TranscriptionSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            },
            atomicTerms: atomicTerms
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
}
