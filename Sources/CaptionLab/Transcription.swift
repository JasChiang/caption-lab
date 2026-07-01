import AVFoundation
import Foundation
import Speech

// Extracted verbatim from PalmierPro/Transcription/Transcription.swift (models moved to Models.swift).
// The SpeechTranscriber/SpeechAnalyzer API resolves locales without SFSpeechRecognizer authorization,
// so this front-end is unchanged — see the note above availableSupportedLocales().
enum Transcription {
    // Backstop only: long enough never to abort a slow cold start of the on-device speech service,
    // short enough that a true XPC wedge fails with a clear error instead of spinning forever.
    private static let speechServiceTimeout: Duration = .seconds(60)

    static func transcribeVideoAudio(videoURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil, sourceRange: ClosedRange<Double>? = nil, conditioning: AudioConditioning = AudioConditioning()) async throws -> TranscriptionResult {
        let tempAudioURL = try await extractAudioTrack(from: videoURL, range: sourceRange)
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }
        let result = try await transcribe(fileURL: tempAudioURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale, conditioning: conditioning)
        return result.offsetting(by: sourceRange?.lowerBound ?? 0)
    }

    static func supportedLocales() async -> [Locale] {
        do {
            return try await availableSupportedLocales()
        } catch {
            Log.transcription.warning(
                "supported locales unavailable error=\(error.localizedDescription)",
                telemetry: "Transcription locales unavailable",
                data: ["error": error.localizedDescription]
            )
            return []
        }
    }

    static func bestSupportedLocale(from supported: [Locale]) -> Locale? {
        let candidates = Locale.preferredLanguages.map(Locale.init(identifier:)) + [Locale.current]
        return matchLocale(candidates: candidates, supported: supported)
    }

    static func matchLocale(candidates: [Locale], supported: [Locale]) -> Locale? {
        for candidate in candidates {
            guard let lang = candidate.language.languageCode?.identifier else { continue }
            let sameLang = supported.filter { $0.language.languageCode?.identifier == lang }
            guard !sameLang.isEmpty else { continue }
            let region = candidate.region?.identifier
            return sameLang.first { $0.region?.identifier == region } ?? sameLang.first
        }
        return nil
    }

    static func transcribe(fileURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil, sourceRange: ClosedRange<Double>? = nil, conditioning: AudioConditioning = AudioConditioning()) async throws -> TranscriptionResult {
        if let sourceRange {
            let tempURL = try await extractAudioTrack(from: fileURL, range: sourceRange)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let result = try await transcribe(fileURL: tempURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale, conditioning: conditioning)
            return result.offsetting(by: sourceRange.lowerBound)
        }

        let supported = try await availableSupportedLocales()
        let locale: Locale
        if let preferredLocale, let match = matchLocale(candidates: [preferredLocale], supported: supported) {
            locale = match
        } else if let auto = bestSupportedLocale(from: supported) {
            locale = auto
        } else {
            throw TranscriptionError.unsupportedLocale((preferredLocale ?? Locale.current).identifier(.bcp47))
        }
        Log.transcription.notice(
            "transcribe locale=\(locale.identifier(.bcp47))",
            telemetry: "Transcription started",
            data: [
                "locale": locale.identifier(.bcp47),
                "censorProfanity": censorProfanity,
                "hasPreferredLocale": preferredLocale != nil
            ]
        )

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censorProfanity ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange],
        )

        let installRequest = try await withSpeechTimeout("Speech model lookup") {
            try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        }
        if let install = installRequest {
            Log.transcription.notice(
                "install model start locale=\(locale.identifier)",
                telemetry: "Transcription model install started",
                data: ["locale": locale.identifier(.bcp47)]
            )
            do {
                try await install.downloadAndInstall()
            } catch {
                Log.transcription.warning(
                    "install model failed locale=\(locale.identifier) error=\(error.localizedDescription)",
                    telemetry: "Transcription model install failed",
                    data: ["locale": locale.identifier(.bcp47), "error": error.localizedDescription]
                )
                throw TranscriptionError.modelInstallFailed(error.localizedDescription)
            }
            Log.transcription.notice(
                "install model ok locale=\(locale.identifier)",
                telemetry: "Transcription model install finished",
                data: ["locale": locale.identifier(.bcp47)]
            )
        }

        // Pre-ASR conditioning: normalize/compress (quiet or fading speakers) and, when the clip is genuinely
        // fast, time-stretch it SLOWER so the recognizer stops swallowing run-together syllables. Word/segment
        // timings come back on the conditioned clock and are scaled by `timeScale` to land on source time.
        // Conditioning is pure upside — any failure returns nil and we analyze the untouched extract.
        var analysisURL = fileURL
        var conditionedURL: URL? = nil
        var timeScale = 1.0
        if !conditioning.isNoop, let cond = await AudioConditioner.condition(url: fileURL, options: conditioning) {
            analysisURL = cond.url
            conditionedURL = cond.url
            timeScale = cond.report.timeScale
            Log.transcription.notice(
                "conditioned audio \(cond.report.summary)",
                telemetry: "Transcription audio conditioned",
                data: ["timeScale": cond.report.timeScale, "stretched": cond.report.stretched, "syllablesPerSecond": cond.report.syllablesPerSecond]
            )
        }
        defer { if let conditionedURL { try? FileManager.default.removeItem(at: conditionedURL) } }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: analysisURL)
        } catch {
            throw TranscriptionError.audioExtractionFailed(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let resultsTask = Task { () throws -> [SpeechTranscriber.Result] in
            var acc: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results { acc.append(result) }
            return acc
        }

        Log.transcription.notice("analyze start file=\(fileURL.lastPathComponent)", telemetry: "Transcription analysis started")
        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            resultsTask.cancel()
            Log.transcription.warning(
                "analyze failed error=\(error.localizedDescription)",
                telemetry: "Transcription analysis failed",
                data: ["error": error.localizedDescription]
            )
            throw TranscriptionError.analysisFailed(error.localizedDescription)
        }

        let collected: [SpeechTranscriber.Result]
        do {
            collected = try await resultsTask.value
        } catch {
            throw TranscriptionError.analysisFailed(error.localizedDescription)
        }

        let decoded = decodeResults(collected, locale: locale, timeScale: timeScale)
        Log.transcription.notice(
            "ok textChars=\(decoded.text.count) words=\(decoded.words.count) lang=\(decoded.language ?? "?")",
            telemetry: "Transcription finished",
            data: [
                "textChars": decoded.text.count,
                "words": decoded.words.count,
                "segments": decoded.segments.count,
                "language": decoded.language ?? "unknown"
            ]
        )
        return decoded
    }

    /// Decode the asset's audio track to a PCM file with AVAssetReader
    private static func extractAudioTrack(from videoURL: URL, range: ClosedRange<Double>? = nil) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.tracksSafely(withMediaType: .audio).first else {
            throw TranscriptionError.audioExtractionFailed("No audio track in \(videoURL.lastPathComponent)")
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw TranscriptionError.audioExtractionFailed(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else {
            throw TranscriptionError.audioExtractionFailed("Cannot read audio from \(videoURL.lastPathComponent)")
        }
        reader.add(output)
        if let range {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-stt-\(UUID().uuidString).caf")
        Log.transcription.notice(
            "extract start video=\(videoURL.lastPathComponent)",
            telemetry: "Transcription audio extraction started",
            data: ["hasRange": range != nil, "rangeSeconds": range.map { $0.upperBound - $0.lowerBound } ?? 0]
        )

        guard reader.startReading() else {
            throw TranscriptionError.audioExtractionFailed(reader.error?.localizedDescription ?? "Reader could not start")
        }

        var audioFile: AVAudioFile?
        while let sample = output.copyNextSampleBuffer() {
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd) else { continue }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            pcm.frameLength = frames
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            )
            if audioFile == nil {
                audioFile = try AVAudioFile(
                    forWriting: outURL,
                    settings: format.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
            }
            try audioFile?.write(from: pcm)
        }

        if reader.status == .failed {
            throw TranscriptionError.audioExtractionFailed(reader.error?.localizedDescription ?? "Read failed")
        }
        guard audioFile != nil else {
            throw TranscriptionError.audioExtractionFailed("No audio samples in \(videoURL.lastPathComponent)")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        Log.transcription.notice(
            "extract ok bytes=\(bytes) out=\(outURL.lastPathComponent)",
            telemetry: "Transcription audio extraction finished",
            data: ["bytes": bytes, "hasRange": range != nil]
        )
        return outURL
    }

    /// Each `Result` is one endpointed segment; emit it as a TranscriptionSegment
    /// (text + time range) and walk its runs into per-token TranscriptionWords.
    private static func decodeResults(
        _ results: [SpeechTranscriber.Result],
        locale: Locale,
        timeScale: Double = 1,
    ) -> TranscriptionResult {
        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        var fullText = ""

        // Timings are on the conditioned clock; scale back to source time (identity when not time-stretched).
        for result in results {
            let attributed = result.text
            fullText += String(attributed.characters)

            let segmentText = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segmentText.isEmpty {
                segments.append(TranscriptionSegment(
                    text: segmentText,
                    start: result.range.start.seconds * timeScale,
                    end: result.range.end.seconds * timeScale
                ))
            }

            for run in attributed.runs {
                let runText = String(attributed[run.range].characters)
                let trimmed = runText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let range = run.audioTimeRange
                let start = range.map { $0.start.seconds * timeScale }
                let end = range.map { ($0.start + $0.duration).seconds * timeScale }
                words.append(TranscriptionWord(text: trimmed, start: start, end: end))
            }
        }

        return TranscriptionResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            language: locale.identifier(.bcp47),
            words: words,
            segments: segments,
        )
    }

    // The new SpeechTranscriber/SpeechAnalyzer API resolves locales without SFSpeechRecognizer
    // authorization (verified: transcription works with no auth gate). Only guard against an
    // unresponsive speech service with a timeout.
    private static func availableSupportedLocales() async throws -> [Locale] {
        try await withSpeechTimeout("Speech locale lookup") {
            await SpeechTranscriber.supportedLocales
        }
    }

    private static func withSpeechTimeout<T: Sendable>(
        _ operationName: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTimeout(operationName, duration: speechServiceTimeout, operation: operation)
    }

    private static func withTimeout<T: Sendable>(
        _ operationName: String,
        duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = TimeoutState<T>()
        let operationTask = Task {
            do {
                state.succeed(try await operation())
            } catch {
                state.fail(error)
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: duration)
                operationTask.cancel()
                state.fail(TranscriptionError.speechServiceTimedOut(operationName))
            } catch {}
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.setContinuation(continuation)
            }
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            state.fail(CancellationError())
        }
    }
}

private final class TimeoutState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func succeed(_ value: T) {
        complete(.success(value))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
