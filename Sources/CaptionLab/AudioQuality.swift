import Foundation

/// Always-on source-quality analysis that runs on the RAW audio (before any conditioning). It detects the
/// speech pathologies conditioning CANNOT fix and surfaces them as honest warnings, instead of pretending a
/// heuristic "cleaned" them:
///   • Clipping / 爆音 — samples already pinned to full scale are irreversibly distorted; no gain or filter
///     brings the lost waveform back. All we can do is tell the user their source is clipped.
///   • Low SNR / noisy or music bed — a loud noise/music floor between words drags recognition down. True
///     source separation needs an ML model (out of scope for a system-frameworks-only build); the honest move
///     is to flag it so the user can pick a cleaner take.
/// Everything here is measured, not fixed — deliberately. Reverb and speaker-overlap SEPARATION are omitted
/// rather than faked: a reliable dereverb / diarization-separation needs a trained model, and a cheap
/// heuristic would mostly cry wolf.
enum AudioQuality {
    struct Report: Sendable, Codable {
        var clippingFraction: Double              // fraction of samples pinned near full scale
        var snrDb: Double                         // rough speech-to-floor ratio from envelope percentiles
        var musicFraction: Double = 0             // fraction dominated by music (Apple SoundAnalysis)
        var musicRanges: [ClosedRange<Double>] = []
        var warnings: [String]                    // user-facing, empty when the source is clean
    }

    // Tunable thresholds (untuned — validate on real clips).
    private static let clipLevel: Float = 0.98        // |sample| at/above this counts as clipped
    private static let clipWarnFraction = 0.002       // >0.2% clipped → warn
    private static let lowSNRWarnDb = 12.0            // below this → noisy background
    private static let musicWarnFraction = 0.15       // >15% music → warn

    static func analyze(url: URL) async -> Report? {
        guard let floats = try? await AudioConditioner.readMonoFloats(url: url),
              floats.count > Int(AudioConditioner.sampleRate * 0.3) else { return nil }

        // Clipping: measured on the raw source (normalization would move the peaks, so this must run first).
        var clipped = 0
        for v in floats where abs(v) >= clipLevel { clipped += 1 }
        let clippingFraction = Double(clipped) / Double(floats.count)

        // SNR proxy: RMS envelope at 20 ms hops; speech ≈ 90th percentile, noise floor ≈ 10th percentile.
        let hop = 320
        var env: [Float] = []
        var i = 0
        while i < floats.count {
            let n = min(hop, floats.count - i)
            var sum: Float = 0
            for j in i..<(i + n) { sum += floats[j] * floats[j] }
            env.append((sum / Float(n)).squareRoot())
            i += n
        }
        let sorted = env.sorted()
        let speech = percentile(sorted, 0.90)
        let floor = max(percentile(sorted, 0.10), 1e-6)
        let snrDb = speech > 1e-6 ? Double(20 * log10f(speech / floor)) : 0

        // Apple SoundAnalysis: a trained model that separates background MUSIC from plain noise (which the
        // SNR proxy can't). Detection only — recognition over music is expected to be worse.
        let music = await SoundClassifier.detectMusic(url: url)

        var warnings: [String] = []
        if clippingFraction > clipWarnFraction {
            warnings.append(String(format: "Clipping: %.1f%% of samples are distorted — a clipped source can't be recovered; use a cleaner take if possible.", clippingFraction * 100))
        }
        if let music, music.musicFraction > musicWarnFraction {
            let where_ = music.ranges.prefix(3).map { mmss($0.lowerBound) + "–" + mmss($0.upperBound) }.joined(separator: ", ")
            warnings.append(String(format: "Background music in %.0f%% of the clip (%@) — recognition drops over music; separation is out of scope.", music.musicFraction * 100, where_))
        }
        if snrDb < lowSNRWarnDb {
            warnings.append(String(format: "Low SNR (~%.0f dB) — noisy background; recognition accuracy will drop.", snrDb))
        }
        return Report(clippingFraction: clippingFraction, snrDb: snrDb,
                      musicFraction: music?.musicFraction ?? 0, musicRanges: music?.ranges ?? [],
                      warnings: warnings)
    }

    private static func mmss(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(p * Double(sorted.count - 1))))
        return sorted[idx]
    }
}
