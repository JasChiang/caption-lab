import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var vm: PipelineViewModel
    @State private var dropTargeted = false

    var body: some View {
        HSplitView {
            // Left: track + player + timeline
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                headerBar
                dropZone
                TrackListView(vm: vm)
                    .frame(height: 132)
                playerAndControls
                TimelineView(vm: vm)
                trackTotals
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.lg)
            .frame(minWidth: 640)

            // Right: controls + results
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    ControlsPanel(vm: vm)
                    ResultsPanels(vm: vm)
                }
                .padding(Theme.Space.lg)
            }
            .frame(minWidth: 380, idealWidth: 440)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("CaptionLab").font(Theme.ui(20, .bold)).foregroundStyle(Theme.text)
            Text("caption-correction pipeline · multi-clip track").font(Theme.ui(12)).foregroundStyle(Theme.faint)
            Spacer()
            Text(vm.statusLine).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1)
        }
    }

    // MARK: Drop zone

    private var dropZone: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 18)).foregroundStyle(dropTargeted ? Theme.accent : Theme.dim)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop videos here to build a track").font(Theme.ui(13, .medium)).foregroundStyle(Theme.text)
                Text("Multiple at once; add more anytime; drag to reorder below.").font(Theme.ui(11)).foregroundStyle(Theme.faint)
            }
            Spacer()
            Button("Add files…") { openPanel() }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6, 4]))
                .foregroundStyle(dropTargeted ? Theme.accent : Theme.stroke)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK { vm.addFiles(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collector = URLCollector()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collector.add(url) }
                else if let u = item as? URL { collector.add(u) }
            }
        }
        group.notify(queue: .main) { vm.addFiles(collector.snapshot()) }
    }

    // MARK: Player + transport / preview controls

    private var playerAndControls: some View {
        VStack(spacing: Theme.Space.sm) {
            AVPlayerViewRepresentable(player: vm.player)
                .frame(minHeight: 240)
                .overlay(alignment: .bottom) {
                    if !vm.currentCaption.isEmpty {
                        Text(vm.currentCaption)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                            .padding(.bottom, 16)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.stroke))

            HStack(spacing: Theme.Space.md) {
                Button { vm.togglePlay() } label: { Image(systemName: "playpause.fill") }
                Text(String(format: "%@ / %@", tc(vm.currentTime), tc(vm.previewCutsApplied ? vm.totalCutDuration : vm.totalRawDuration)))
                    .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                Spacer()
                Picker("", selection: Binding(get: { vm.previewCutsApplied }, set: { vm.setPreviewCutsApplied($0) })) {
                    Text("Joined (raw)").tag(false)
                    Text("Joined + cuts").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 260).labelsHidden()
            }
        }
    }

    private var trackTotals: some View {
        HStack(spacing: Theme.Space.lg) {
            totalStat("Raw", tc(vm.totalRawDuration), Theme.dim)
            totalStat("After cuts", tc(vm.totalCutDuration), Theme.accent)
            totalStat("Removed", String(format: "%.2fs", vm.totalSecondsSaved), Theme.cut)
            Spacer()
            Text("\(vm.clips.count) clip(s)").font(Theme.mono(11)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, Theme.Space.xs)
    }

    private func totalStat(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Text(label).font(Theme.ui(11)).foregroundStyle(Theme.faint)
            Text(value).font(Theme.mono(12, .semibold)).foregroundStyle(color)
        }
    }
}

/// Thread-safe URL accumulator for concurrent NSItemProvider callbacks.
final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    func snapshot() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

func tc(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
}

// Wraps AppKit's AVPlayerView directly instead of SwiftUI's `VideoPlayer`.
// SwiftUI's `VideoPlayer` (module _AVKit_SwiftUI) crashes on the Xcode 27 beta
// toolchain: the runtime fails to demangle the AVPlayerView (`So12AVPlayerViewC`)
// superclass metadata and aborts. This representable is behavior-equivalent.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
