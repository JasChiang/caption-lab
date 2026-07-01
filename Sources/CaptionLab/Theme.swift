import SwiftUI

// Tiny local style system (this repo has no AppTheme). Pro-video-tool feel: dark, monospace data columns,
// a single accent for the waveform, red for cut regions, green/red for PASS/FAIL.
enum Theme {
    // Colors
    static let bg = Color(red: 0.075, green: 0.078, blue: 0.094)
    static let panel = Color(red: 0.125, green: 0.13, blue: 0.152)
    static let panelHi = Color(red: 0.17, green: 0.176, blue: 0.204)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.29, green: 0.74, blue: 0.92)     // waveform cyan
    static let accentDim = Color(red: 0.29, green: 0.74, blue: 0.92).opacity(0.28)
    static let cut = Color(red: 0.93, green: 0.28, blue: 0.30)        // cut regions
    static let pass = Color(red: 0.32, green: 0.82, blue: 0.44)
    static let fail = Color(red: 0.93, green: 0.32, blue: 0.34)
    static let text = Color(white: 0.92)
    static let dim = Color(white: 0.56)
    static let faint = Color(white: 0.38)
    static let addGreen = Color(red: 0.34, green: 0.78, blue: 0.46)

    // Spacing
    enum Space { static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 14, lg: CGFloat = 22, xl: CGFloat = 32 }
    enum Radius { static let sm: CGFloat = 5, md: CGFloat = 9, lg: CGFloat = 14 }

    // Fonts
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

extension View {
    /// Standard dark panel container.
    func panelCard() -> some View {
        self
            .padding(Theme.Space.md)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}
