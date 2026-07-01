import SwiftUI

// MARK: - Per-clip stage dots

struct StageDots: View {
    let stages: [PipelineStage]
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 3 : Theme.Space.xs) {
            ForEach(stages) { s in
                Circle()
                    .fill(color(s.state))
                    .frame(width: compact ? 8 : 10, height: compact ? 8 : 10)
                    .overlay(dotOverlay(s.state))
                    .help("\(s.id). \(s.name): \(label(s.state))")
            }
        }
    }

    @ViewBuilder private func dotOverlay(_ st: StageState) -> some View {
        if st == .running { Circle().stroke(Theme.accent, lineWidth: 1.5).scaleEffect(1.4) }
    }

    private func color(_ st: StageState) -> Color {
        switch st {
        case .pending: Theme.faint.opacity(0.4)
        case .running: Theme.accent
        case .done: Theme.pass
        case .skipped: Theme.dim.opacity(0.6)
        case .failed: Theme.fail
        }
    }
    private func label(_ st: StageState) -> String {
        switch st {
        case .pending: "pending"; case .running: "running…"; case .done: "done"
        case .skipped: "skipped"; case .failed(let m): "failed — \(m)"
        }
    }
}

// MARK: - Track list (reorderable, removable)

struct TrackListView: View {
    @Bindable var vm: PipelineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text("TRACK").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.faint).kerning(1)
                Spacer()
                if vm.isRunning { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }
            if vm.clips.isEmpty {
                Text("No clips yet.").font(Theme.ui(12)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(Array(vm.clips.enumerated()), id: \.element.id) { idx, clip in
                        row(idx: idx, clip: clip)
                            .listRowBackground(clip.id == vm.selectedClipID ? Theme.panelHi : Theme.panel)
                            .listRowSeparatorTint(Theme.stroke)
                            .contentShape(Rectangle())
                            .onTapGesture { vm.selectedClipID = clip.id }
                    }
                    .onMove { vm.move(from: $0, to: $1) }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
        }
        .panelCard()
    }

    private func row(idx: Int, clip: ClipModel) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text("\(idx + 1)").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: Theme.Space.sm) {
                    Text(tc(clip.duration)).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                    if let p = clip.timingPass {
                        Text(p ? "1:1 PASS" : "FAIL").font(Theme.mono(10, .bold)).foregroundStyle(p ? Theme.pass : Theme.fail)
                    }
                    if clip.secondsSaved > 0 {
                        Text(String(format: "-%.1fs", clip.secondsSaved)).font(Theme.mono(10)).foregroundStyle(Theme.cut)
                    }
                }
            }
            Spacer()
            StageDots(stages: clip.stages, compact: true)
            Button { vm.remove(clip) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }
                .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
