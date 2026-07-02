import Foundation
import Observation
import SwiftUI

/// Session-wide Gemini token/cost ledger, fed by every `GeminiClient` generateContent call and shown in the
/// GUI "GEMINI USAGE / COST" panel. Cost estimates use the official pricing page
/// (https://ai.google.dev/gemini-api/docs/pricing, fetched 2026-07-02, PAID tier, per 1M tokens):
///   pro tier:   $2.00 in / $12.00 out   (≤200k-token prompts; the >200k surcharge is NOT modeled)
///   flash tier: $1.50 in / $9.00 out
///   lite tier:  $0.10 text-in / $0.30 audio+video-in / $0.40 out
/// Estimates only: Google reprices, and a "latest" alias can resolve to a different tier server-side.
/// NOTE: records hop to the main actor; in the CLI (whose main thread blocks on a semaphore) they never
/// materialize — the dashboard is a GUI feature.
@MainActor
@Observable
final class GeminiUsageLedger {
    static let shared = GeminiUsageLedger()

    struct Row: Identifiable {
        var id: String { model }
        let model: String
        var calls = 0
        var promptTokens = 0      // total prompt tokens (incl. audio/video share)
        var avPromptTokens = 0    // audio/video/image share of prompt tokens (priced separately on lite)
        var outputTokens = 0
    }
    private(set) var rows: [Row] = []

    struct Rates { let inText: Double; let inAV: Double; let out: Double }
    static func rates(for model: String) -> Rates {
        let m = model.lowercased()
        if m.contains("lite") { return Rates(inText: 0.10, inAV: 0.30, out: 0.40) }
        if m.contains("pro") { return Rates(inText: 2.00, inAV: 2.00, out: 12.00) }
        return Rates(inText: 1.50, inAV: 1.50, out: 9.00)   // flash tier
    }

    func cost(of r: Row) -> Double {
        let rates = Self.rates(for: r.model)
        let textIn = Double(max(0, r.promptTokens - r.avPromptTokens))
        return textIn / 1e6 * rates.inText
            + Double(r.avPromptTokens) / 1e6 * rates.inAV
            + Double(r.outputTokens) / 1e6 * rates.out
    }
    var totalCost: Double { rows.reduce(0) { $0 + cost(of: $1) } }
    var totalIn: Int { rows.reduce(0) { $0 + $1.promptTokens } }
    var totalOut: Int { rows.reduce(0) { $0 + $1.outputTokens } }

    func add(model: String, promptTokens: Int, avPromptTokens: Int, outputTokens: Int) {
        if let i = rows.firstIndex(where: { $0.model == model }) {
            rows[i].calls += 1
            rows[i].promptTokens += promptTokens
            rows[i].avPromptTokens += avPromptTokens
            rows[i].outputTokens += outputTokens
        } else {
            rows.append(Row(model: model, calls: 1, promptTokens: promptTokens,
                            avPromptTokens: avPromptTokens, outputTokens: outputTokens))
        }
    }
    func reset() { rows = [] }

    /// Record from any context (GeminiClient is nonisolated).
    nonisolated static func record(model: String, promptTokens: Int, avPromptTokens: Int, outputTokens: Int) {
        Task { @MainActor in
            shared.add(model: model, promptTokens: promptTokens, avPromptTokens: avPromptTokens, outputTokens: outputTokens)
        }
    }

    static func fmt(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.2fM", Double(n) / 1e6)
            : n >= 1_000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
}

// MARK: - Dashboard panel (right column)

struct UsagePanel: View {
    var body: some View {
        let ledger = GeminiUsageLedger.shared
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("GEMINI USAGE / COST").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.faint).kerning(1)
                Spacer()
                if !ledger.rows.isEmpty {
                    Button("Reset") { ledger.reset() }
                        .buttonStyle(.plain).font(Theme.ui(10)).foregroundStyle(Theme.dim)
                }
            }
            if ledger.rows.isEmpty {
                Text("No Gemini calls yet this session.").font(Theme.ui(11)).foregroundStyle(Theme.faint)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(ledger.rows.sorted { ledger.cost(of: $0) > ledger.cost(of: $1) }) { r in
                        HStack(spacing: Theme.Space.xs) {
                            Text(r.model).font(Theme.mono(10)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text("\(r.calls)×").font(Theme.mono(9)).foregroundStyle(Theme.faint)
                            Text("\(GeminiUsageLedger.fmt(r.promptTokens)) in").font(Theme.mono(9)).foregroundStyle(Theme.dim)
                            Text("\(GeminiUsageLedger.fmt(r.outputTokens)) out").font(Theme.mono(9)).foregroundStyle(Theme.dim)
                            Text(String(format: "$%.4f", ledger.cost(of: r)))
                                .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    Divider().overlay(Theme.stroke)
                    HStack {
                        Text("TOTAL").font(Theme.mono(10, .bold)).foregroundStyle(Theme.text)
                        Text("\(GeminiUsageLedger.fmt(ledger.totalIn)) in / \(GeminiUsageLedger.fmt(ledger.totalOut)) out")
                            .font(Theme.mono(9)).foregroundStyle(Theme.dim)
                        Spacer()
                        Text(String(format: "$%.4f", ledger.totalCost)).font(Theme.mono(11, .bold)).foregroundStyle(Theme.pass)
                    }
                    Text("Est. @ paid-tier rates (ai.google.dev/gemini-api/docs/pricing, 2026-07). Pro >200k surcharge not modeled; audio-in priced separately on the lite tier only.")
                        .font(Theme.ui(9)).foregroundStyle(Theme.faint)
                }
            }
        }
        .panelCard()
    }
}
