import AVFoundation
import Foundation

/// Which "second listener" the retranscribe stage (stage 5) uses to re-hear a suspect span.
/// `.gemini` is the cloud path (unchanged default); `.localASR` runs an OFFLINE local Whisper model via the
/// sidecar below — free, no API, and the MODEL is a knob (a general multilingual Whisper by default, a
/// locale-tuned checkpoint if you point it at one). The stage's map-agreement gate and energy-peak
/// re-timing are identical either way, so swapping the listener never changes the mechanism.
enum RefineBackend: String, Sendable, CaseIterable {
    case gemini, localASR
    var label: String { self == .gemini ? "Gemini (cloud)" : "Local ASR (offline)" }
}

enum LocalASRError: LocalizedError {
    case notSetUp
    case exportFailed(String)
    case process(String)
    case decode(String)
    var errorDescription: String? {
        switch self {
        case .notSetUp: "Local ASR backend not set up — run ./setup.sh --asr (creates .venv + installs mlx-whisper)."
        case .exportFailed(let r): "Audio export for local ASR failed: \(r)"
        case .process(let r): "Local ASR process error: \(r)"
        case .decode(let r): "Could not decode local ASR output: \(r)"
        }
    }
}

/// Shells out to the Python local-ASR sidecar (`asr/local_asr.py`) running in the repo's `.venv`.
/// A GENERAL, offline "second ear": transcribes an audio span with a local Whisper-family model (MLX). It
/// is deliberately NOT tied to any one language — the model id comes from `$CAPTIONLAB_ASR_MODEL` (default a
/// general multilingual Whisper), so a Taiwan user can point it at a zh-tuned checkpoint without the pipeline
/// itself hardcoding a locale. Mirrors QwenAligner's sidecar plumbing (shared `.venv`, serial subprocess).
enum LocalASR {
    static func pythonPath() -> String {
        if let p = ProcessInfo.processInfo.environment["CAPTIONLAB_PYTHON"], !p.isEmpty { return p }
        return FileManager.default.currentDirectoryPath + "/.venv/bin/python"
    }
    static func scriptPath() -> String {
        if let p = ProcessInfo.processInfo.environment["CAPTIONLAB_ASR_SCRIPT"], !p.isEmpty { return p }
        return FileManager.default.currentDirectoryPath + "/asr/local_asr.py"
    }

    /// True when the venv python and sidecar script are both present (else the GUI shows a setup hint).
    static func isAvailable() -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: pythonPath()) && fm.fileExists(atPath: scriptPath())
    }

    /// bcp47 → the ISO-639-1 code Whisper expects (nil to let the model auto-detect, which also lets a
    /// code-switching clip fall back gracefully).
    static func mapLanguage(_ bcp47: String?) -> String? {
        let code = (bcp47 ?? "").lowercased()
        if code.hasPrefix("zh") || code.hasPrefix("yue") { return "zh" }
        if code.hasPrefix("en") { return "en" }
        if code.hasPrefix("ja") { return "ja" }
        if code.hasPrefix("ko") { return "ko" }
        if code.hasPrefix("es") { return "es" }
        if code.hasPrefix("fr") { return "fr" }
        if code.hasPrefix("de") { return "de" }
        return nil
    }

    /// Re-transcribe the source-time span `[start,end]` of `url` with the local model. `biasHint` (e.g. the
    /// content map's dialogue for this window) is passed as Whisper's initial-prompt to nudge proper nouns.
    /// Returns the verbatim text; timing is assigned by the caller on energy peaks (same as the Gemini path).
    static func transcribeSpan(url: URL, start: Double, end: Double,
                               language: String?, biasHint: String? = nil) async throws -> String {
        guard isAvailable() else { throw LocalASRError.notSetUp }
        guard end > start else { return "" }
        let wav = try await exportWAV(from: url, range: start...end)
        defer { try? FileManager.default.removeItem(at: wav) }

        var args = [scriptPath(), "--audio", wav.path]
        if let lang = mapLanguage(language) { args += ["--language", lang] }
        if let hint = biasHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            args += ["--prompt", String(hint.prefix(220))]
        }
        let data = try await runProcess(pythonPath(), args)
        return try decodeText(data)
    }

    // MARK: - Audio export (16 kHz mono WAV, reusing AudioTrackReader) — same as QwenAligner.exportWAV

    private static func exportWAV(from url: URL, range: ClosedRange<Double>?) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("captionlab-asr-\(UUID().uuidString.prefix(8)).wav")
        var file: AVAudioFile?
        do {
            try await AudioTrackReader.read(from: url, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], range: range) { pcm in
                if file == nil {
                    file = try AVAudioFile(forWriting: out, settings: pcm.format.settings,
                                           commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                try file?.write(from: pcm)
            }
        } catch { throw LocalASRError.exportFailed(error.localizedDescription) }
        guard file != nil else { throw LocalASRError.exportFailed("no audio track in \(url.lastPathComponent)") }
        return out
    }

    // MARK: - Subprocess (blocking work kept off the calling actor)

    // Serial: only ONE local-ASR subprocess runs at a time so peak RAM stays ~one model, and it never
    // contends with the Qwen aligner for the GPU (each has its own serial queue; both are heavy MLX loads).
    private static let asrQueue = DispatchQueue(label: "io.captionlab.local-asr")

    private static func runProcess(_ exe: String, _ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            asrQueue.async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                do { try p.run() } catch {
                    cont.resume(throwing: LocalASRError.process("could not launch \(exe): \(error.localizedDescription)")); return
                }
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let msg = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(throwing: LocalASRError.process("exit \(p.terminationStatus) — \(msg.suffix(300))"))
                } else {
                    cont.resume(returning: out)
                }
            }
        }
    }

    private struct Payload: Decodable { let text: String }

    private static func decodeText(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw LocalASRError.decode("empty output") }
        do {
            return try JSONDecoder().decode(Payload.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw LocalASRError.decode("\(error.localizedDescription) — got: \(raw.prefix(200))")
        }
    }
}
