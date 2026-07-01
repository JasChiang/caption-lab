import AVFoundation
import Foundation

/// The two timing backends compared in the A/B view.
enum AlignerBackend: String, Sendable, CaseIterable {
    case appleASR   // Apple SpeechTranscriber word/char timings (+ corrected-text 1:1 writeback)
    case qwenMLX    // Qwen3-ForcedAligner (mlx-audio) aligning the FINAL corrected text directly to audio
    var label: String { self == .appleASR ? "Apple ASR" : "Qwen (MLX)" }
}

/// Which backend(s) the GUI runs / shows.
enum AlignerMode: String, Sendable, CaseIterable {
    case apple, qwen, both
    var runsQwen: Bool { self != .apple }
    var showsApple: Bool { self != .qwen }
    var label: String { switch self { case .apple: "Apple only"; case .qwen: "Qwen only"; case .both: "Both (A/B)" } }
}

enum QwenAlignerError: LocalizedError {
    case notSetUp
    case exportFailed(String)
    case process(String)
    case decode(String)
    var errorDescription: String? {
        switch self {
        case .notSetUp: "Qwen backend not set up — run ./setup.sh (creates .venv + installs mlx-audio)."
        case .exportFailed(let r): "Audio export for the aligner failed: \(r)"
        case .process(let r): "Aligner process error: \(r)"
        case .decode(let r): "Could not decode aligner output: \(r)"
        }
    }
}

/// Shells out to the Python forced-aligner sidecar (`aligner/qwen_align.py`) running in the repo's `.venv`.
/// Aligns a KNOWN transcript to audio → `[TranscriptionWord]`, on its own clock (no Apple ASR, no
/// 1:1-count writeback constraint), so segments where correction changed word count/boundaries still align.
enum QwenAligner {
    /// The aligner model's practical single-pass audio limit.
    static let maxAudioSeconds: Double = 300

    static func pythonPath() -> String {
        if let p = ProcessInfo.processInfo.environment["CAPTIONLAB_PYTHON"], !p.isEmpty { return p }
        return FileManager.default.currentDirectoryPath + "/.venv/bin/python"
    }
    static func scriptPath() -> String {
        if let p = ProcessInfo.processInfo.environment["CAPTIONLAB_ALIGNER"], !p.isEmpty { return p }
        return FileManager.default.currentDirectoryPath + "/aligner/qwen_align.py"
    }

    /// True when the venv python and sidecar script are both present (else the GUI shows a setup hint).
    static func isAvailable() -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: pythonPath()) && fm.fileExists(atPath: scriptPath())
    }

    static func mapLanguage(_ bcp47: String?) -> String {
        let code = (bcp47 ?? "").lowercased()
        if code.hasPrefix("zh") || code.hasPrefix("yue") { return "Chinese" }
        if code.hasPrefix("en") { return "English" }
        if code.hasPrefix("ja") { return "Japanese" }
        if code.hasPrefix("ko") { return "Korean" }
        if code.hasPrefix("es") { return "Spanish" }
        if code.hasPrefix("fr") { return "French" }
        if code.hasPrefix("de") { return "German" }
        return "English"
    }

    /// Align `text` to `url`'s audio. Returns per-word/char timings in SOURCE seconds.
    static func align(text: String, language: String?, url: URL) async throws -> [TranscriptionWord] {
        guard isAvailable() else { throw QwenAlignerError.notSetUp }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let wav = try await exportWAV(from: url)
        defer { try? FileManager.default.removeItem(at: wav) }

        let args = [scriptPath(), "--audio", wav.path, "--text", trimmed, "--language", mapLanguage(language)]
        let data = try await runProcess(pythonPath(), args)
        return try decode(data)
    }

    // MARK: - Audio export (16 kHz mono WAV, reusing AudioTrackReader)

    private static func exportWAV(from url: URL) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("captionlab-align-\(UUID().uuidString.prefix(8)).wav")
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
            ]) { pcm in
                if file == nil {
                    file = try AVAudioFile(forWriting: out, settings: pcm.format.settings,
                                           commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                try file?.write(from: pcm)
            }
        } catch { throw QwenAlignerError.exportFailed(error.localizedDescription) }
        guard file != nil else { throw QwenAlignerError.exportFailed("no audio track in \(url.lastPathComponent)") }
        return out
    }

    // MARK: - Subprocess (blocking work kept off the calling actor)

    // Serial: only ONE aligner subprocess runs at a time, so peak RAM stays ~one model (safe on 16 GB)
    // even when clips are processed concurrently.
    private static let alignQueue = DispatchQueue(label: "io.captionlab.qwen-aligner")

    private static func runProcess(_ exe: String, _ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            alignQueue.async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                do { try p.run() } catch {
                    cont.resume(throwing: QwenAlignerError.process("could not launch \(exe): \(error.localizedDescription)")); return
                }
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let msg = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(throwing: QwenAlignerError.process("exit \(p.terminationStatus) — \(msg.suffix(300))"))
                } else {
                    cont.resume(returning: out)
                }
            }
        }
    }

    private struct AlignedWord: Decodable { let text: String; let start: Double; let end: Double }

    private static func decode(_ data: Data) throws -> [TranscriptionWord] {
        guard !data.isEmpty else { throw QwenAlignerError.decode("empty output") }
        do {
            let words = try JSONDecoder().decode([AlignedWord].self, from: data)
            return words.map { TranscriptionWord(text: $0.text, start: $0.start, end: $0.end) }
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw QwenAlignerError.decode("\(error.localizedDescription) — got: \(raw.prefix(200))")
        }
    }
}
