import Foundation

// Extracted from PalmierPro/Editor/RippleEngine.swift — ONLY `FrameRange` and `RippleEngine.mergeRanges`
// (the clip-shift ripple logic depends on the Clip model and isn't needed by the cut planner).

/// A half-open `[start, end)` frame interval on a single track. Used to describe
/// the gaps that a ripple edit needs to close.
struct FrameRange: Equatable, Sendable {
    let start: Int
    let end: Int
    var length: Int { end - start }
}

enum RippleEngine {
    static func mergeRanges(_ ranges: [FrameRange]) -> [FrameRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [FrameRange] = []
        for range in sorted {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = FrameRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
