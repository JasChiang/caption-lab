import SwiftUI

// Waveform + word-chip timeline across the WHOLE track on one global RAW time axis (clip A then B …),
// with clip-boundary markers, translucent-red cut regions, a playhead, and — for the A/B aligner —
// TWO clickable word-chip lanes: "Apple ASR" and "Qwen (MLX)", so timing can be compared per token.
struct TimelineView: View {
    @Bindable var vm: PipelineViewModel

    private let pxPerSec: CGFloat = 90
    private let waveH: CGFloat = 70
    private let laneH: CGFloat = 30
    private let gutter: CGFloat = 62

    private var showApple: Bool { vm.alignerMode.showsApple }
    private var showQwen: Bool { vm.alignerMode.runsQwen }
    private var laneCount: Int { (showApple ? 1 : 0) + (showQwen ? 1 : 0) }
    private var chipsH: CGFloat { CGFloat(max(1, laneCount)) * laneH }
    private var totalH: CGFloat { waveH + chipsH }

    private var total: Double { max(vm.totalRawDuration, 0.001) }
    private var contentWidth: CGFloat { max(CGFloat(total) * pxPerSec, 240) }

    private struct Chip { let x: CGFloat; let w: CGFloat; let text: String; let cut: Bool; let global: Double }
    private struct Band { let x: CGFloat; let w: CGFloat }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("TIMELINE").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.faint).kerning(1)
            HStack(alignment: .top, spacing: 0) {
                laneLabels
                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in draw(ctx: &ctx, size: size) }
                            .frame(width: contentWidth, height: totalH)

                        if showApple { chipLane(appleChips, lane: 0) }
                        if showQwen { chipLane(qwenChips, lane: showApple ? 1 : 0) }

                        // ISOLATED playhead: the ONLY view here that reads vm.currentTime. @Observable
                        // invalidates per body that touched a property — if the playhead lived in THIS body,
                        // the whole timeline (hundreds of chips + waveform Canvas) would rebuild 33×/s during
                        // playback, pinning the main thread (video freezes, clicks go dead) while audio
                        // (AVPlayer, off-main) kept going.
                        PlayheadBar(vm: vm, pxPerSec: pxPerSec, height: totalH)
                    }
                    .frame(width: contentWidth, height: totalH)
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.stroke))
            }
            .frame(height: totalH + 12)
        }
    }

    private struct PlayheadBar: View {
        var vm: PipelineViewModel
        let pxPerSec: CGFloat
        let height: CGFloat
        var body: some View {
            Rectangle().fill(Theme.text)
                .frame(width: 1.5, height: height)
                .position(x: CGFloat(vm.currentTime) * pxPerSec, y: height / 2)
        }
    }

    // MARK: Lane labels (fixed leading gutter)

    private var laneLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("wave").font(Theme.mono(9)).foregroundStyle(Theme.faint)
                .frame(width: gutter, height: waveH, alignment: .trailing).padding(.trailing, Theme.Space.xs)
            if showApple { laneLabel("Apple", Theme.text, state: nil) }
            if showQwen { laneLabel("Qwen", Theme.accent, state: aggregateQwenState) }
        }
    }

    private func laneLabel(_ text: String, _ color: Color, state: StageState?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(text).font(Theme.mono(10, .semibold)).foregroundStyle(color)
            if let state, state == .running { Text("aligning…").font(Theme.mono(8)).foregroundStyle(Theme.faint) }
            else if let state, case .failed = state { Text("failed").font(Theme.mono(8)).foregroundStyle(Theme.cut) }
        }
        .frame(width: gutter, height: laneH, alignment: .trailing).padding(.trailing, Theme.Space.xs)
    }

    private var aggregateQwenState: StageState {
        if vm.clips.contains(where: { $0.qwenState == .running }) { return .running }
        if vm.clips.contains(where: { if case .failed = $0.qwenState { return true } else { return false } }) { return .failed("") }
        return .done
    }

    // MARK: Chip lane

    // Positional identity (stable across re-evaluations) — the old `id = UUID()` minted new IDs every body
    // pass, making SwiftUI treat every chip as removed+reinserted on each rebuild.
    private func chipLane(_ chips: [Chip], lane: Int) -> some View {
        let yCenter = waveH + CGFloat(lane) * laneH + laneH / 2
        return ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
            Text(chip.text)
                .font(Theme.mono(10))
                .foregroundStyle(chip.cut ? Theme.cut : Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(chip.cut ? Theme.cut.opacity(0.16) : Theme.panelHi))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(chip.cut ? Theme.cut.opacity(0.5) : Theme.stroke))
                .frame(minWidth: max(chip.w, 14), alignment: .center)
                .position(x: chip.x + max(chip.w, 14) / 2, y: yCenter)
                .onTapGesture { vm.seekRaw(to: chip.global) }
                .help(String(format: "%@  @%.2fs%@", chip.text, chip.global, chip.cut ? "  (cut)" : ""))
        }
    }

    // MARK: Canvas (waveform, boundaries, cut bands)

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let mid = waveH / 2
        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: size.width, y: mid)) },
                   with: .color(Theme.stroke), lineWidth: 1)

        let globalMax = max(vm.clips.compactMap { $0.envelope?.samples.max() }.max() ?? 1, 0.0001)

        for band in cutBands {
            ctx.fill(Path(CGRect(x: band.x, y: 0, width: max(band.w, 1), height: totalH)), with: .color(Theme.cut.opacity(0.16)))
            ctx.stroke(Path(CGRect(x: band.x, y: 0, width: max(band.w, 1), height: waveH)), with: .color(Theme.cut.opacity(0.5)), lineWidth: 1)
        }

        for (idx, clip) in vm.clips.enumerated() {
            guard let env = clip.envelope, !env.samples.isEmpty else { continue }
            let off = vm.rawOffset(of: idx)
            var wave = Path()
            let stride = max(1, env.samples.count / max(1, Int(CGFloat(clip.duration) * pxPerSec)))
            var i = 0
            while i < env.samples.count {
                let t = off + Double(i) * env.hopSeconds
                let x = CGFloat(t) * pxPerSec
                let amp = CGFloat(env.samples[i] / Float(globalMax)) * (waveH / 2 - 2)
                wave.move(to: CGPoint(x: x, y: mid - amp))
                wave.addLine(to: CGPoint(x: x, y: mid + amp))
                i += stride
            }
            ctx.stroke(wave, with: .color(Theme.accent.opacity(0.85)), lineWidth: 1)
        }

        for idx in vm.clips.indices where idx > 0 {
            let x = CGFloat(vm.rawOffset(of: idx)) * pxPerSec
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: totalH)) },
                       with: .color(Theme.text.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        if showApple && showQwen {
            let y = waveH + laneH
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                       with: .color(Theme.stroke), lineWidth: 1)
        }
    }

    // MARK: Chip data

    private var appleChips: [Chip] { chips(for: { $0.words }) }
    private var qwenChips: [Chip] { chips(for: { $0.qwenWords }) }

    private func chips(for pick: (ClipModel) -> [TranscriptionWord]) -> [Chip] {
        var out: [Chip] = []
        for (idx, clip) in vm.clips.enumerated() {
            let off = vm.rawOffset(of: idx)
            let cuts = clip.cutSpans
            for w in pick(clip) {
                guard let s = w.start, let e = w.end else { continue }
                let g = off + s
                let mid = (s + e) / 2
                let isCut = cuts.contains { $0.contains(mid) }
                out.append(Chip(x: CGFloat(g) * pxPerSec, w: CGFloat(e - s) * pxPerSec, text: w.text, cut: isCut, global: g))
            }
        }
        return out
    }

    private var cutBands: [Band] {
        var out: [Band] = []
        for (idx, clip) in vm.clips.enumerated() {
            let off = vm.rawOffset(of: idx)
            for span in clip.cutSpans {
                out.append(Band(x: CGFloat(off + span.lowerBound) * pxPerSec, w: CGFloat(span.upperBound - span.lowerBound) * pxPerSec))
            }
        }
        return out
    }
}
