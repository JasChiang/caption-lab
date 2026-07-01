import AVFoundation
import Foundation

// Headless CLI, reachable via `swift run CaptionLab --cli <media> [options]`. The GUI is the primary
// entry (see Entry.swift); this preserves the original scriptable pipeline for CI / batch use.
enum CLIRunner {
    static let usage = """
    Usage: swift run CaptionLab --cli <path-to-media> [options]

    Options:
      --glossary term1,term2   Extra glossary terms (merged with content-map-harvested terms).
      --no-retranscribe        Skip stage 5 (Gemini-audio re-transcription of suspect spans).
      --cut-heuristic          Use the heuristic stutter/filler detector instead of the LLM (stage 6).
      --aggressiveness <x>     tight | balanced | loose  (stage-6 keep-gap; default balanced).
      --model <gemini-model>   Gemini model for content map + text correction (default gemini-flash-latest).
      --dump-json <dir>        Write per-stage JSON.
      --asr-json <file>        Load a pre-exported TranscriptionResult instead of running live Apple ASR.
      --language <lang>        Content-map description language (default "Traditional Chinese").
      --fps <n>                Nominal fps for the stage-6 seconds↔frames conversion (default: read from
                               the video, else 30).

    Environment:
      GEMINI_API_KEY           Required for the content map, glossary, correction, retranscribe, and
                               LLM-cut stages.
    """

    private final class Box: @unchecked Sendable { var code: Int32 = 0 }

    /// Blocking bridge from the synchronous `@main` dispatcher.
    static func run(_ argv: [String]) -> Never {
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        Task.detached {
            box.code = await main(argv)
            sem.signal()
        }
        sem.wait()
        exit(box.code)
    }

    private static func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

    private static func main(_ argv: [String]) async -> Int32 {
        var mediaPath: String?
        var glossaryArg: [String] = []
        var doRetranscribe = true
        var useHeuristic = false
        var aggressiveness: CutAggressiveness = .balanced
        var model = GeminiClient.defaultModel
        var dumpDir: String?
        var asrJSONPath: String?
        var language = "Traditional Chinese"
        var fpsOverride: Double?

        var i = 0
        let args = argv.filter { $0 != "--cli" }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--glossary": i += 1; if i < args.count { glossaryArg = args[i].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            case "--no-retranscribe": doRetranscribe = false
            case "--cut-heuristic": useHeuristic = true
            case "--aggressiveness": i += 1; if i < args.count, let v = CutAggressiveness(rawValue: args[i]) { aggressiveness = v }
            case "--model": i += 1; if i < args.count { model = args[i] }
            case "--dump-json": i += 1; if i < args.count { dumpDir = args[i] }
            case "--asr-json": i += 1; if i < args.count { asrJSONPath = args[i] }
            case "--language": i += 1; if i < args.count { language = args[i] }
            case "--fps": i += 1; if i < args.count { fpsOverride = Double(args[i]) }
            case "-h", "--help": print(usage); return 0
            default:
                if a.hasPrefix("--") { err("Error: Unknown option: \(a)\n\n\(usage)\n"); return 1 }
                else if mediaPath == nil { mediaPath = a }
            }
            i += 1
        }

        func header(_ n: Int, _ title: String) {
            print("\n" + String(repeating: "═", count: 72))
            print("[\(n)] \(title)")
            print(String(repeating: "═", count: 72))
        }
        func mmss(_ s: Double) -> String { String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }
        func dump<T: Encodable>(_ value: T, _ name: String) {
            guard let dir = dumpDir else { return }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let out = dirURL.appendingPathComponent(name)
            if let data = try? enc.encode(value) { try? data.write(to: out); print("  · dumped \(out.path)") }
        }

        guard let mediaPath else { print(usage); return 1 }
        let mediaURL = URL(fileURLWithPath: (mediaPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else { err("Error: File not found: \(mediaURL.path)\n"); return 1 }
        if ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.isEmpty != false {
            err("Error: GEMINI_API_KEY is not set.\n"); return 1
        }

        print("CaptionLab (CLI) — \(mediaURL.lastPathComponent)")
        print("model=\(model)  retranscribe=\(doRetranscribe)  cut=\(useHeuristic ? "heuristic" : "llm")  aggressiveness=\(aggressiveness.rawValue)")

        // fps for stage 6
        var fps = fpsOverride ?? 30
        if fpsOverride == nil {
            let asset = AVURLAsset(url: mediaURL)
            if let track = try? await asset.tracksSafely(withMediaType: .video).first,
               let rate = try? await track.load(.nominalFrameRate), rate > 0 { fps = Double(rate) }
        }

        // [1] Content map
        header(1, "CONTENT MAP (Gemini video understanding)")
        var contentSegments: [ContentSegment] = []
        do {
            let r = try await MediaDescriber.describeVideoContentMap(url: mediaURL, language: language, model: model)
            contentSegments = r.segments
            if let label = r.label { print("Summary: \(label)") }
            print("\(r.segments.count) segment(s) · \(r.usage.summary)\n")
            for seg in r.segments {
                print("  [\(mmss(seg.startSeconds))–\(mmss(seg.endSeconds))] \(seg.visual)")
                if let d = seg.dialogue, !d.isEmpty { print("      \(seg.speaker.map { "[\($0)] " } ?? "")dialogue: \(d)") }
            }
            let speakers = Array(Set(r.segments.compactMap(\.speaker))).sorted()
            if !speakers.isEmpty { print("\nSpeakers detected: \(speakers.joined(separator: ", "))") }
            dump(r.segments, "contentmap.json")
        } catch { print("Content map failed: \(error.localizedDescription)") }

        // [2] Raw ASR
        header(2, "RAW ASR (Apple SpeechTranscriber)")
        let asr: TranscriptionResult
        if let asrJSONPath {
            let url = URL(fileURLWithPath: (asrJSONPath as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url), let loaded = try? JSONDecoder().decode(TranscriptionResult.self, from: data) else {
                err("Error: Could not load --asr-json \(url.path).\n"); return 1
            }
            asr = loaded; print("Loaded pre-exported ASR from \(url.path)")
        } else {
            do { asr = try await Transcription.transcribeVideoAudio(videoURL: mediaURL) }
            catch {
                err("\nLive Apple ASR failed: \(error.localizedDescription)\nRe-run with --asr-json <file> to test stages 3–7 offline.\n")
                return 2
            }
        }
        print("language=\(asr.language ?? "?")  words=\(asr.words.count)  segments=\(asr.segments.count)")
        for w in asr.words.prefix(20) {
            print("  \(w.start.map { String(format: "%.2f", $0) } ?? "—")–\(w.end.map { String(format: "%.2f", $0) } ?? "—")  \(w.text)")
        }
        dump(asr, "asr.json")

        // [3] Glossary
        header(3, "HARVESTED GLOSSARY TERMS")
        let harvested = await CaptionPipeline.contentMapGlossaryTerms(contentSegments: contentSegments)
        let glossary = Array(Set(harvested + glossaryArg)).sorted()
        print("harvested: \(harvested.isEmpty ? "(none)" : harvested.joined(separator: ", "))")
        print("effective: \(glossary.isEmpty ? "(empty)" : glossary.joined(separator: ", "))")

        // [4] Correction
        header(4, "TEXT CORRECTION (Gemini, 1:1 segment writeback)")
        let corr = await TranscriptCorrector.correct(asr, model: model, glossary: glossary,
                                                     contentSegments: contentSegments)
        if !corr.corrected { print("Correction FAILED — using RAW transcript.") }
        print("changed segments: \(corr.changes.count)")
        for c in corr.changes { print("  BEFORE: \(c.from)\n  AFTER : \(c.to)\n") }
        if !corr.result.atomicTerms.isEmpty { print("atomic terms: \(corr.result.atomicTerms.joined(separator: ", "))") }
        dump(corr.result, "corrected.json")

        // [5] Retranscribe
        var working = corr.result
        if doRetranscribe {
            header(5, "RETRANSCRIBE SUSPECT SPANS (Gemini audio vs content map)")
            if contentSegments.isEmpty { print("No content map → skipped.") }
            else {
                var cache: [String: String] = [:]
                let r = await CaptionPipeline.retranscribeSuspectSpans(result: corr.result, url: mediaURL, contentSegments: contentSegments, spanCache: &cache)
                working = r.result
                if r.retranscribes.isEmpty { print("No suspect spans exceeded the threshold.") }
                else { for rt in r.retranscribes { print("  @\(rt.t)\n    BEFORE: \(rt.from)\n    AFTER : \(rt.to)\n") } }
            }
        } else { print("\n[5] RETRANSCRIBE — skipped (--no-retranscribe)") }
        dump(working, "retranscribed.json")

        // [6] Cut stutters / disfluencies
        header(6, "CUT STUTTERS / DISFLUENCIES (WordCutPlanner)")
        let cut = await CutStutters.plan(words: working.words, fps: fps,
                                         aggressiveness: aggressiveness, detector: useHeuristic ? .heuristic : .llm,
                                         url: mediaURL)
        if cut.llmFellBack { print("(LLM cut detector failed — fell back to heuristic.)") }
        print("detector=\(cut.mode.rawValue)  fps=\(String(format: "%.3f", fps))  cut \(cut.cutWords.count) word(s) → \(String(format: "%.2f", cut.secondsSaved))s removed across \(cut.cutRangesSeconds.count) range(s)")
        for (idx, w) in zip(cut.cutIndices, cut.cutWords) {
            print("  cut #\(idx): \(w.text) [\(w.start.map { String(format: "%.2f", $0) } ?? "—")–\(w.end.map { String(format: "%.2f", $0) } ?? "—")]")
        }
        print("tightened words: \(cut.keptWords.map(\.text).joined(separator: " "))")
        dump(working, "final.json")

        // [7] Timing-preservation check
        header(7, "TIMING-PRESERVATION CHECK (applyCorrectedText 1:1 writeback)")
        let finalSegs = working.segments
        let writeback = TranscriptCorrector.applyCorrectedText(to: asr.words, segments: finalSegs, corrected: finalSegs.map(\.text))
        var drift = 0
        if writeback.count == asr.words.count {
            for (a, b) in zip(asr.words, writeback) where a.start != b.start || a.end != b.end {
                drift += 1
                print("  DRIFT: \(a.text) (\(a.start ?? -1),\(a.end ?? -1)) → \(b.text) (\(b.start ?? -1),\(b.end ?? -1))")
            }
            let swaps = zip(asr.words, writeback).filter { $0.text != $1.text }.count
            print("  words: \(asr.words.count)  text swapped: \(swaps)  timing drift: \(drift)")
        } else { drift = -1; print("  word-count mismatch — invariant violated") }
        print(drift == 0 ? "  RESULT: PASS — all original timings preserved 1:1." : "  RESULT: FAIL.")
        return 0
    }
}
