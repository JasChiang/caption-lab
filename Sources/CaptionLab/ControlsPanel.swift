import SwiftUI

struct ControlsPanel: View {
    @Bindable var vm: PipelineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("REQUIREMENTS")

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                fieldLabel("GEMINI_API_KEY")
                SecureField("paste key", text: $vm.apiKey)
                    .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                Text(vm.apiKey.isEmpty ? "Required for content map, glossary, correction, retranscribe, LLM cut." : "Key set (kept in-process; not persisted).")
                    .font(Theme.ui(10)).foregroundStyle(vm.apiKey.isEmpty ? Theme.fail : Theme.faint)
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                fieldLabel("Glossary (comma / newline separated)")
                TextField("e.g. macOS, AirDrop, 正念減壓", text: $vm.glossaryText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(Theme.mono(11)).lineLimit(1...3)
            }

            Toggle("Skip retranscribe (stage 5)", isOn: $vm.skipRetranscribe)
                .font(Theme.ui(12)).foregroundStyle(Theme.text).tint(Theme.accent)

            Divider().overlay(Theme.stroke)
            sectionTitle("AUDIO CONDITIONING (pre-ASR)")

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Toggle("Normalize + compress (quiet / fading speakers)", isOn: $vm.conditioning.normalize)
                    .font(Theme.ui(12)).foregroundStyle(Theme.text).tint(Theme.accent)
                Toggle("Slow fast speech before ASR (experimental)", isOn: $vm.conditioning.slowFastSpeech)
                    .font(Theme.ui(12)).foregroundStyle(Theme.text).tint(Theme.accent)
                Toggle("Denoise (high-pass + gentle gate)", isOn: $vm.conditioning.denoise)
                    .font(Theme.ui(12)).foregroundStyle(Theme.text).tint(Theme.accent)
                Text("Normalize lifts a quiet talker and the trailing 的/了/嗎 a fading voice drops; harmless on clean audio. Slow-down is OFF by default — A/B showed time-stretch smears consonant onsets (幹→趕) and swaps errors instead of reducing them; try it only on genuinely extreme fast speech.")
                    .font(Theme.ui(10)).foregroundStyle(Theme.faint)
            }

            Divider().overlay(Theme.stroke)
            sectionTitle("STAGE 6 — CUT STUTTERS")

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                fieldLabel("Detector")
                Picker("", selection: $vm.cutDetector) {
                    Text("LLM (default)").tag(CutStutters.Detector.llm)
                    Text("Heuristic").tag(CutStutters.Detector.heuristic)
                }.pickerStyle(.segmented).labelsHidden()

                fieldLabel("Aggressiveness (keep-gap)")
                Picker("", selection: $vm.aggressiveness) {
                    ForEach(CutAggressiveness.allCases, id: \.self) { a in
                        Text("\(a.rawValue) · \(Int(a.keptGapMs))ms").tag(a)
                    }
                }.pickerStyle(.segmented).labelsHidden()
            }

            Divider().overlay(Theme.stroke)
            sectionTitle("TIMING BACKEND (A/B)")

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Picker("", selection: $vm.alignerMode) {
                    ForEach(AlignerMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
                }.pickerStyle(.segmented).labelsHidden()

                if vm.qwenAvailable {
                    Text("Qwen aligns the FINAL corrected text directly to audio (its own clock, no 1:1 writeback limit).")
                        .font(Theme.ui(10)).foregroundStyle(Theme.faint)
                    Button { vm.runQwen() } label: { Label("Align with Qwen", systemImage: "waveform.badge.magnifyingglass") }
                        .buttonStyle(.bordered)
                        .disabled(vm.isRunning || !vm.alignerMode.runsQwen || vm.clips.allSatisfy { $0.afterRetranscribe == nil })
                } else {
                    Text("Qwen backend unavailable — run ./setup.sh (creates .venv + installs mlx-audio).")
                        .font(Theme.ui(10)).foregroundStyle(Theme.cut)
                }
            }

            Divider().overlay(Theme.stroke)

            HStack(spacing: Theme.Space.sm) {
                Button { vm.run() } label: {
                    Label(vm.isRunning ? "Running…" : "Run pipeline", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(vm.isRunning || vm.clips.isEmpty)

                Button { vm.rerunCut() } label: { Label("Re-cut", systemImage: "scissors") }
                    .buttonStyle(.bordered)
                    .disabled(vm.isRunning || vm.clips.allSatisfy { $0.afterRetranscribe == nil })
            }

            timingBadge
        }
        .panelCard()
    }

    private var timingBadge: some View {
        let checked = vm.clips.filter { $0.timingPass != nil }
        let allPass = !checked.isEmpty && checked.allSatisfy { $0.timingPass == true }
        let anyFail = checked.contains { $0.timingPass == false }
        return Group {
            if !checked.isEmpty {
                HStack {
                    Circle().fill(allPass ? Theme.pass : Theme.fail).frame(width: 10, height: 10)
                    Text(allPass ? "TIMING 1:1 — PASS (all clips)" : (anyFail ? "TIMING — FAIL" : "TIMING — mixed"))
                        .font(Theme.mono(11, .bold)).foregroundStyle(allPass ? Theme.pass : Theme.fail)
                    Spacer()
                    Text("\(checked.count)/\(vm.clips.count) checked").font(Theme.mono(10)).foregroundStyle(Theme.faint)
                }
                .padding(Theme.Space.sm)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill((allPass ? Theme.pass : Theme.fail).opacity(0.12)))
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.faint).kerning(1)
    }
    private func fieldLabel(_ t: String) -> some View {
        Text(t).font(Theme.ui(10)).foregroundStyle(Theme.dim)
    }
}
