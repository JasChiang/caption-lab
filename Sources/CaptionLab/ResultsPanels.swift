import SwiftUI

// Results for the SELECTED clip: content map, glossary, correction diff, retranscribe, cut summary.
struct ResultsPanels: View {
    @Bindable var vm: PipelineViewModel

    var body: some View {
        if let clip = vm.selectedClip {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    Text("CLIP").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.faint).kerning(1)
                    Text(clip.name).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    StageDots(stages: clip.stages)
                }
                audioQuality(clip)
                cutSummary(clip)
                qwenCard(clip)
                contentMap(clip)
                glossary(clip)
                diff(clip)
                retranscribe(clip)
            }
        } else {
            Text("Add a clip and run the pipeline to see results.")
                .font(Theme.ui(12)).foregroundStyle(Theme.faint).panelCard()
        }
    }

    // MARK: Audio quality (raw source)

    private func audioQuality(_ clip: ClipModel) -> some View {
        card("AUDIO QUALITY (raw source)") {
            if let q = clip.audioQuality {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack {
                        pill(String(format: "SNR ~%.0f dB", q.snrDb), q.snrDb < 12 ? Theme.cut : Theme.pass)
                        pill(String(format: "clip %.1f%%", q.clippingFraction * 100), q.clippingFraction > 0.002 ? Theme.fail : Theme.dim)
                        Spacer()
                    }
                    if q.warnings.isEmpty {
                        Text("Clean source — no clipping or noisy/music bed detected.")
                            .font(Theme.ui(11)).foregroundStyle(Theme.faint)
                    } else {
                        ForEach(Array(q.warnings.enumerated()), id: \.offset) { _, w in
                            Text("⚠︎ \(w)").font(Theme.ui(11)).foregroundStyle(Theme.cut)
                        }
                    }
                }
            } else { empty("not analyzed yet") }
        }
    }

    // MARK: Cut summary

    private func cutSummary(_ clip: ClipModel) -> some View {
        card("CUT SUMMARY (stage 6)") {
            if let cut = clip.cut {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack {
                        pill("\(cut.mode.rawValue)", Theme.accent)
                        if cut.llmFellBack { pill("LLM→heuristic fallback", Theme.cut) }
                        Spacer()
                        Text(String(format: "%d word(s) · %.2fs · %d range(s)", cut.cutWords.count, cut.secondsSaved, cut.cutRangesSeconds.count))
                            .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    }
                    if cut.cutWords.isEmpty {
                        Text("No disfluencies cut.").font(Theme.ui(11)).foregroundStyle(Theme.faint)
                    } else {
                        FlowText(cut.cutWords.map(\.text), color: Theme.cut, strike: true)
                        Text("Tightened:").font(Theme.ui(10)).foregroundStyle(Theme.faint).padding(.top, 2)
                        Text(cut.keptWords.map(\.text).joined(separator: " "))
                            .font(Theme.mono(11)).foregroundStyle(Theme.text).textSelection(.enabled)
                    }
                }
            } else { empty() }
        }
    }

    // MARK: Qwen aligner A/B

    private func qwenCard(_ clip: ClipModel) -> some View {
        card("QWEN ALIGNER (A/B)") {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack {
                    Text("Apple \(clip.words.count) tok").font(Theme.mono(10)).foregroundStyle(Theme.text)
                    Text("·").foregroundStyle(Theme.faint)
                    Text("Qwen \(clip.qwenWords.count) tok").font(Theme.mono(10)).foregroundStyle(Theme.accent)
                    Spacer()
                    switch clip.qwenState {
                    case .running: pill("aligning…", Theme.accent)
                    case .done: pill("aligned", Theme.pass)
                    case .failed: pill("failed", Theme.fail)
                    case .skipped: pill("skipped", Theme.dim)
                    case .pending: pill("idle", Theme.faint)
                    }
                }
                if let w = clip.qwenWarning { Text(w).font(Theme.ui(10)).foregroundStyle(Theme.cut) }
                if let e = clip.qwenError { Text(e).font(Theme.ui(10)).foregroundStyle(Theme.fail) }
                else if clip.qwenWords.isEmpty { empty("Set backend to Qwen/Both and align.") }
                else {
                    Text("Qwen timings align the FINAL corrected text on its own clock.")
                        .font(Theme.ui(10)).foregroundStyle(Theme.faint)
                    Text(clip.qwenWords.prefix(40).map(\.text).joined(separator: " "))
                        .font(Theme.mono(11)).foregroundStyle(Theme.text).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Content map

    private func contentMap(_ clip: ClipModel) -> some View {
        card("CONTENT MAP (stage 1)") {
            if clip.contentSegments.isEmpty { empty() }
            else {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if let l = clip.contentLabel { Text(l).font(Theme.ui(11, .medium)).foregroundStyle(Theme.text) }
                    ForEach(Array(clip.contentSegments.enumerated()), id: \.offset) { _, seg in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("[\(tc(seg.startSeconds))–\(tc(seg.endSeconds))] \(seg.visual)")
                                .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                            if let d = seg.dialogue {
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                                    if let sp = seg.speaker {
                                        Text(sp).font(Theme.mono(10, .medium)).foregroundStyle(Theme.accent)
                                    }
                                    Text(d).font(Theme.mono(10)).foregroundStyle(Theme.text.opacity(0.8))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Glossary

    private func glossary(_ clip: ClipModel) -> some View {
        card("GLOSSARY (stage 3)") {
            if clip.effectiveGlossary.isEmpty { empty() }
            else { FlowText(clip.effectiveGlossary, color: Theme.accent, strike: false) }
        }
    }

    // MARK: Correction diff

    private func diff(_ clip: ClipModel) -> some View {
        card("CORRECTION DIFF (stage 4)") {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if !clip.correctionSucceeded { pill("correction failed — raw", Theme.fail) }
                if clip.diffChanges.isEmpty { empty("No segment changes.") }
                else {
                    ForEach(clip.diffChanges) { c in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.from).font(Theme.mono(10)).foregroundStyle(Theme.cut).strikethrough()
                            Text(c.to).font(Theme.mono(10)).foregroundStyle(Theme.addGreen)
                        }
                    }
                }
                if !clip.atomicTerms.isEmpty {
                    Text("atomic terms: \(clip.atomicTerms.joined(separator: ", "))")
                        .font(Theme.ui(10)).foregroundStyle(Theme.faint)
                }
            }
        }
    }

    // MARK: Retranscribe

    private func retranscribe(_ clip: ClipModel) -> some View {
        card("RETRANSCRIBE (stage 5)") {
            if clip.stateOf(5) == .skipped { empty("Skipped.") }
            else if clip.retranscribeRows.isEmpty { empty("No suspect spans re-transcribed.") }
            else {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(clip.retranscribeRows) { r in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("@\(r.t)").font(Theme.mono(9)).foregroundStyle(Theme.faint)
                            Text(r.from).font(Theme.mono(10)).foregroundStyle(Theme.cut).strikethrough()
                            Text(r.to).font(Theme.mono(10)).foregroundStyle(Theme.addGreen)
                        }
                    }
                }
            }
        }
    }

    // MARK: helpers

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.faint).kerning(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }
    private func empty(_ t: String = "—") -> some View { Text(t).font(Theme.ui(11)).foregroundStyle(Theme.faint) }
    private func pill(_ t: String, _ c: Color) -> some View {
        Text(t).font(Theme.mono(9, .semibold)).foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.15)))
    }
}

/// Wrapping run of small labelled tokens.
struct FlowText: View {
    let items: [String]; let color: Color; let strike: Bool
    init(_ items: [String], color: Color, strike: Bool) { self.items = items; self.color = color; self.strike = strike }
    var body: some View {
        FlowLayout(spacing: Theme.Space.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                Text(s).font(Theme.mono(10)).foregroundStyle(color).strikethrough(strike)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.14)))
            }
        }
    }
}

/// Minimal flow (wrapping) layout — no external deps.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.minX + maxW, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
