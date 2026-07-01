import Foundation

// Extracted from PalmierPro/MediaPanel/CaptionsTab/CaptionBuilder.swift — ONLY the `units` helper and
// its `isCJKChar` dependency (the rest of CaptionBuilder is caption line-breaking, unused here).
enum CaptionBuilder {
    /// Splits text into per-"word" units: one CJK character per unit, a run of letters/digits per unit.
    /// `keepPunctuation` attaches trailing punctuation to the preceding unit (for display) instead of
    /// dropping it (for matching) — either way punctuation never starts a new unit, so the COUNT is the
    /// same. Used to align corrected text onto ASR word timings (counts are stable across spelling fixes
    /// and added punctuation, unlike a character count).
    static func units(_ s: String, keepPunctuation: Bool) -> [String] {
        var units: [String] = []
        var run = ""
        func flush() { if !run.isEmpty { units.append(run); run = "" } }
        for ch in s {
            if isCJKChar(ch) { flush(); units.append(String(ch)) }
            else if ch.isLetter || ch.isNumber { run.append(ch) }
            else if keepPunctuation, !ch.isWhitespace {           // attach to the current/previous unit
                if !run.isEmpty { run.append(ch) }
                else if !units.isEmpty { units[units.count - 1].append(ch) }
            } else { flush() }
        }
        flush()
        return units
    }

    static func isCJKChar(_ c: Character) -> Bool {
        c.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value) || (0xAC00...0xD7A3).contains($0.value)
                || (0x20000...0x3FFFD).contains($0.value)
        }
    }
}
