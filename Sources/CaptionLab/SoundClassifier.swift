import AVFoundation
import Foundation
import SoundAnalysis

/// Apple's built-in SoundAnalysis classifier (`SNClassifySoundRequest`, `.version1`) run OFFLINE over a whole
/// file. Unlike our SNR heuristic this is a trained ~300-category model, so it reliably tells background
/// MUSIC apart from plain noise — the one "needs an ML model" item from the last pass that Apple actually
/// ships a model for. This is DETECTION only: it flags where music dominates so the user can expect lower
/// accuracy (and pick a cleaner take); it does NOT separate music from speech.
enum SoundClassifier {
    struct MusicReport: Sendable {
        var musicFraction: Double            // fraction of the clip's duration dominated by music
        var ranges: [ClosedRange<Double>]    // source-time spans where music dominates
    }

    // A classifier window counts as "music" when "music" or "singing" clears this confidence.
    private static let musicThreshold: Double = 0.5
    private static let musicIdentifiers: Set<String> = ["music", "singing"]

    static func detectMusic(url: URL) async -> MusicReport? {
        await withCheckedContinuation { (cont: CheckedContinuation<MusicReport?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let observer = Observer(threshold: musicThreshold, identifiers: musicIdentifiers)
                do {
                    let analyzer = try SNAudioFileAnalyzer(url: url)
                    let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                    try analyzer.add(request, withObserver: observer)
                    analyzer.analyze()   // synchronous — blocks this queue until the whole file is processed
                } catch {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: observer.report())
            }
        }
    }

    /// Accumulates the per-window classifications the analyzer delivers during `analyze()`.
    private final class Observer: NSObject, SNResultsObserving {
        private let threshold: Double
        private let identifiers: Set<String>
        private var musicWindows: [ClosedRange<Double>] = []
        private var total: Double = 0

        init(threshold: Double, identifiers: Set<String>) {
            self.threshold = threshold; self.identifiers = identifiers
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            let start = r.timeRange.start.seconds
            let end = (r.timeRange.start + r.timeRange.duration).seconds
            guard end.isFinite, start.isFinite else { return }
            total = max(total, end)
            if r.classifications.contains(where: { identifiers.contains($0.identifier) && $0.confidence >= threshold }) {
                musicWindows.append(start...max(start + 0.001, end))
            }
        }

        func report() -> MusicReport {
            let merged = merge(musicWindows)
            let musicDur = merged.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
            return MusicReport(musicFraction: total > 0 ? musicDur / total : 0, ranges: merged)
        }

        /// Merge windows that touch or sit within 0.5 s of each other into contiguous music spans.
        private func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
            let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
            var out: [ClosedRange<Double>] = []
            for r in sorted {
                if let last = out.last, r.lowerBound <= last.upperBound + 0.5 {
                    out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
                } else { out.append(r) }
            }
            return out
        }
    }
}
