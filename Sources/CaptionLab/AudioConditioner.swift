import AVFoundation
import Foundation

/// Pre-ASR audio conditioning knobs. Two independent problems fast/quiet speech creates get two
/// independent levers:
///   • `normalize` (default ON, near-zero risk) — RMS/peak normalize + gentle compression. Lifts a quiet
///     speaker AND the trailing syllables of someone whose volume tails off mid-sentence (的/了/嗎 that
///     otherwise fall under the recognizer's VAD floor and get dropped). Safe to leave on for every clip.
///   • `slowFastSpeech` (default ON, adaptive) — when the measured syllable rate is high, time-stretch the
///     audio SLOWER (pitch preserved) before recognition, so each syllable gets more acoustic frames and the
///     recognizer stops swallowing run-together syllables. Only fires above `fastSyllablesPerSecond`, so a
///     normal-paced clip is untouched. The caller must scale word timings back by `timeScale`.
///   • `denoise` (default OFF, opt-in) — a light high-pass + downward expander for a noisy/quiet source.
///     Off by default because an aggressive gate can chew the ends of quiet words.
struct AudioConditioning: Sendable, Equatable {
    var normalize: Bool = true
    var denoise: Bool = false
    /// Default OFF: A/B on real clips (2026-07-02) showed mild slow-down (0.86×) swaps errors rather than
    /// reducing them — time-stretch smears consonant transients (幹→趕), and the recognizer is trained on
    /// natural-rate speech. Net ≈ 0 at +25% ASR time. Keep as an opt-in experiment for genuinely extreme
    /// fast speech; normalize (harmless, sometimes recovers quiet syllables) stays on.
    var slowFastSpeech: Bool = false

    // Normalization / compression tuning.
    var targetPeak: Float = 0.89              // ≈ -1 dBFS write ceiling
    var maxMakeupGainDb: Float = 24           // don't amplify a near-silent/noise-only source past this
    var compThresholdDb: Float = -24
    var compRatio: Float = 3

    // Fast-speech detection / stretch tuning.
    var fastSyllablesPerSecond: Double = 6.5  // Mandarin runs ~4–5 normal; >~6.5 is genuinely fast
    var minStretchRate: Double = 0.6          // never slow past 0.6× — phase-vocoder artifacts start to hurt
    var maxStretchRate: Double = 0.9          // mildest slow-down we bother applying

    static let off = AudioConditioning(normalize: false, denoise: false, slowFastSpeech: false)
    /// Nothing to do — caller should skip conditioning entirely and use the original audio.
    var isNoop: Bool { !normalize && !denoise && !slowFastSpeech }
}

/// What conditioning actually did to one file — for logging and the `timeScale` the caller needs.
struct AudioConditionReport: Sendable {
    var normalized = false
    var makeupGainDb: Double = 0
    var denoised = false
    var syllablesPerSecond: Double = 0
    var stretched = false
    var stretchRate: Double = 1
    /// Multiply recognizer timings by this to map them back onto the ORIGINAL audio clock. Equals the
    /// stretch rate when slowed (a word at conditioned-time t sits at original-time t·rate), else 1.
    var timeScale: Double = 1

    var summary: String {
        var parts: [String] = []
        if normalized { parts.append(String(format: "normalize %+.1fdB", makeupGainDb)) }
        if denoised { parts.append("denoise") }
        parts.append(String(format: "%.1f syl/s", syllablesPerSecond))
        if stretched { parts.append(String(format: "slow %.2f×", stretchRate)) } else { parts.append("no-slow") }
        return parts.joined(separator: " · ")
    }
}

/// Conditions an audio file in a single offline pass. Every step degrades gracefully: any failure (unreadable
/// track, engine error, format mismatch) makes `condition` return nil and the caller falls back to the
/// untouched original — conditioning is pure upside, never a way to break the pipeline.
enum AudioConditioner {
    static let sampleRate: Double = 16_000
    private static let hopSamples = 160          // 10 ms @ 16 kHz — one CJK syllable ≈ one energy peak

    /// Output container. Apple's on-device analyzer round-trips a float32 CAF cleanly; the Gemini File API is
    /// happiest with a plain int16 WAV.
    enum Container { case caf, wav
        var ext: String { self == .caf ? "caf" : "wav" }
        // Both write int16 LinearPCM — the exact sample format the rest of the pipeline is validated on (the
        // original extract) and the most universally accepted by the Gemini File API. Only the container differs.
        var int16: Bool { true }
        var mimeType: String { self == .caf ? "audio/x-caf" : "audio/wav" }
    }

    struct Conditioned: Sendable { let url: URL; let report: AudioConditionReport }

    /// Produce a conditioned copy of `url`. `forceStretch` slows even a not-measurably-fast clip (used for a
    /// span the recognizer already flagged as garbled — it's suspect regardless of measured rate).
    /// Returns nil (→ caller uses the original) when conditioning is a no-op, the clip is too short to bother,
    /// or anything throws.
    static func condition(url: URL, options: AudioConditioning,
                          forceStretch: Bool = false, container: Container = .caf) async -> Conditioned? {
        guard !options.isNoop else { return nil }
        do {
            var floats = try await readMonoFloats(url: url)
            guard floats.count > Int(sampleRate * 0.2) else { return nil }   // <200 ms: not worth it
            var report = AudioConditionReport()

            if options.denoise {
                highPass(&floats)
                gate(&floats)
                report.denoised = true
            }
            if options.normalize {
                compress(&floats, options)
                let gain = normalizePeak(&floats, options)
                report.normalized = true
                report.makeupGainDb = Double(20 * log10f(max(gain, 1e-6)))
            }

            let rate = syllableRate(floats)
            report.syllablesPerSecond = rate

            var buffer = makeBuffer(floats)
            if options.slowFastSpeech {
                let r = stretchRate(for: rate, options: options, forced: forceStretch)
                if r < 0.999 {
                    buffer = try timeStretch(buffer, rate: Float(r))
                    report.stretched = true
                    report.stretchRate = r
                    report.timeScale = r
                }
            }

            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("captionlab-cond-\(UUID().uuidString.prefix(8)).\(container.ext)")
            try writeSamples(buffer, to: outURL, int16: container.int16)
            return Conditioned(url: outURL, report: report)
        } catch {
            Log.transcription.warning("audio conditioning failed — using original: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Slow-down decision

    /// The playback rate to slow to (pitch preserved). Above the fast threshold we scale inversely with the
    /// measured rate (the faster the talker, the slower we play) clamped to [min,max]; a forced span that
    /// isn't measurably fast still gets the mildest slow-down; a normal-paced clip gets 1.0 (no stretch).
    private static func stretchRate(for rate: Double, options: AudioConditioning, forced: Bool) -> Double {
        if rate > options.fastSyllablesPerSecond {
            return min(options.maxStretchRate, max(options.minStretchRate, options.fastSyllablesPerSecond / rate))
        }
        return forced ? options.maxStretchRate : 1.0
    }

    /// Syllables per VOICED second, estimated from RMS energy peaks (one CJK syllable ≈ one nucleus peak).
    /// Language-general and cheap — no recognition needed, so it can gate the slow-down before ASR runs.
    /// The raw 10 ms envelope has sub-syllable ripple that inflates a naive local-maxima count ~5×, so it is
    /// SMOOTHED (~50 ms) and peaks are required to be at least ~140 ms apart — a syllable nucleus can't recur
    /// faster than that. Without this every clip reads 25–30 syl/s and always trips the fast threshold.
    private static func syllableRate(_ floats: [Float]) -> Double {
        var env: [Float] = []
        var i = 0
        while i < floats.count {
            let n = min(hopSamples, floats.count - i)
            var sum: Float = 0
            for j in i..<(i + n) { sum += floats[j] * floats[j] }
            env.append((sum / Float(n)).squareRoot())
            i += n
        }
        guard env.count > 5, let maxE = env.max(), maxE > 0 else { return 0 }
        // Moving-average smooth over ~50 ms (5 hops).
        let win = 5
        var sm = [Float](repeating: 0, count: env.count)
        for k in env.indices {
            let lo = max(0, k - win / 2), hi = min(env.count - 1, k + win / 2)
            var s: Float = 0
            for j in lo...hi { s += env[j] }
            sm[k] = s / Float(hi - lo + 1)
        }
        let floor = maxE * 0.15
        let minGap = 14   // hops ≈ 140 ms → caps the count at a realistic ~7 syllables/s
        var peaks = 0, voiced = 0, lastPeak = -minGap
        for k in sm.indices {
            if sm[k] >= floor { voiced += 1 }
            if k > 0, k < sm.count - 1, sm[k] >= sm[k - 1], sm[k] > sm[k + 1], sm[k] >= floor, k - lastPeak >= minGap {
                peaks += 1; lastPeak = k
            }
        }
        let voicedSeconds = Double(voiced) * Double(hopSamples) / sampleRate
        guard voicedSeconds > 0.2 else { return 0 }
        return Double(peaks) / voicedSeconds
    }

    // MARK: - DSP passes (in place on the mono float buffer)

    /// One-pole high-pass (~85 Hz) to strip DC / low rumble that survives normalization as amplified boom.
    private static func highPass(_ x: inout [Float]) {
        let r = Float(exp(-2 * Double.pi * 85 / sampleRate))
        var prevX: Float = 0, prevY: Float = 0
        for i in x.indices {
            let y = r * (prevY + x[i] - prevX)
            prevX = x[i]; prevY = y; x[i] = y
        }
    }

    /// Gentle downward expander: attenuate anything below -45 dBFS (between-word hiss) without hard gating,
    /// so quiet word tails survive while the noise floor drops.
    private static func gate(_ x: inout [Float]) {
        let sr = Float(sampleRate)
        let coefA = expf(-1 / (sr * 0.005)), coefR = expf(-1 / (sr * 0.120))
        let thr: Float = -45, ratio: Float = 2
        var env: Float = 0
        for i in x.indices {
            let lvl = abs(x[i])
            env = (lvl > env ? coefA : coefR) * env + (1 - (lvl > env ? coefA : coefR)) * lvl
            let db = 20 * log10f(max(env, 1e-7))
            if db < thr {
                let g = powf(10, max(-18, (db - thr) * (ratio - 1)) / 20)
                x[i] *= g
            }
        }
    }

    /// Soft-knee-ish downward compressor with an attack/release envelope follower. Pulls the loud peaks down
    /// so the following makeup gain can lift the whole utterance — the quiet tails come up without the peaks
    /// clipping. This is what rescues the swallowed sentence-final particles of a fading speaker.
    private static func compress(_ x: inout [Float], _ o: AudioConditioning) {
        let sr = Float(sampleRate)
        let coefA = expf(-1 / (sr * 0.005)), coefR = expf(-1 / (sr * 0.120))
        var env: Float = 0
        for i in x.indices {
            let lvl = abs(x[i])
            let coef = lvl > env ? coefA : coefR
            env = coef * env + (1 - coef) * lvl
            let db = 20 * log10f(max(env, 1e-7))
            if db > o.compThresholdDb {
                let gainDb = -(db - o.compThresholdDb) * (1 - 1 / o.compRatio)
                x[i] *= powf(10, gainDb / 20)
            }
        }
    }

    /// Peak-normalize to `targetPeak`, capping makeup gain so a near-silent or noise-only clip isn't blown up.
    /// Returns the linear gain applied (for the report).
    private static func normalizePeak(_ x: inout [Float], _ o: AudioConditioning) -> Float {
        var peak: Float = 0
        for v in x { peak = max(peak, abs(v)) }
        guard peak > 1e-6 else { return 1 }
        let gain = min(o.targetPeak / peak, powf(10, o.maxMakeupGainDb / 20))
        guard abs(gain - 1) > 0.01 else { return 1 }
        for i in x.indices { x[i] *= gain }
        return gain
    }

    // MARK: - Time-stretch (offline AVAudioEngine, pitch preserved)

    private static func timeStretch(_ input: AVAudioPCMBuffer, rate: Float) throws -> AVAudioPCMBuffer {
        let fmt = input.format
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = rate                                   // <1 = slower; pitch stays put
        engine.attach(player); engine.attach(pitch)
        engine.connect(player, to: pitch, format: fmt)
        engine.connect(pitch, to: engine.mainMixerNode, format: fmt)

        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)
        player.play()

        let target = AVAudioFramePosition(Double(input.frameLength) / Double(rate))
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(target) + 8192),
              let render = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096),
              let outCh = out.floatChannelData, let renderCh = render.floatChannelData else {
            engine.stop()
            throw NSError(domain: "AudioConditioner", code: 1, userInfo: [NSLocalizedDescriptionKey: "stretch buffer alloc failed"])
        }
        defer { engine.stop() }

        while engine.manualRenderingSampleTime < target {
            let need = min(AVAudioFrameCount(target - engine.manualRenderingSampleTime), render.frameCapacity)
            if need == 0 { break }
            let status = try engine.renderOffline(need, to: render)
            switch status {
            case .success:
                let n = Int(render.frameLength)
                if n == 0 { continue }
                let dst = Int(out.frameLength)
                guard dst + n <= Int(out.frameCapacity) else { return out }
                outCh[0].advanced(by: dst).update(from: renderCh[0], count: n)
                out.frameLength += AVAudioFrameCount(n)
            case .insufficientDataFromInputNode:
                return out                                  // player drained — done
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw NSError(domain: "AudioConditioner", code: 2, userInfo: [NSLocalizedDescriptionKey: "offline render error"])
            @unknown default:
                return out
            }
        }
        return out
    }

    // MARK: - IO helpers

    /// Decode a file's first audio track to a flat 16 kHz mono float array. Shared with `AudioQuality`.
    static func readMonoFloats(url: URL) async throws -> [Float] {
        var out: [Float] = []
        try await AudioTrackReader.read(from: url, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]) { pcm in
            guard let ch = pcm.floatChannelData else { return }
            out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(pcm.frameLength)))
        }
        return out
    }

    private static func makeBuffer(_ floats: [Float]) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, floats.count)))!
        buf.frameLength = AVAudioFrameCount(floats.count)
        floats.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { buf.floatChannelData![0].update(from: base, count: floats.count) }
        }
        return buf
    }

    private static func writeSamples(_ buffer: AVAudioPCMBuffer, to url: URL, int16: Bool) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: int16 ? 16 : 32,
            AVLinearPCMIsFloatKey: !int16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !int16,
        ]
        // Provide float32 non-interleaved buffers (our processing format); AVAudioFile encodes to the on-disk
        // format from `settings` — so we can hand it the same buffer whether the file is int16 or float32.
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
