import AppKit
import SwiftUI

// Launched via `swift run` the executable is not an .app bundle, so macOS starts it as a background
// ("Non UI") process with no Dock icon and an unfocused window. Force a regular activation policy and
// bring the window to the front on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Custom entry point: `--cli` runs the headless pipeline (see CLIRunner); otherwise launch the GUI.
@main
struct EntryPoint {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--cli") {
            CLIRunner.run(Array(args.dropFirst()))   // never returns
        }
        CaptionLabApp.main()
    }
}

struct CaptionLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var vm = PipelineViewModel()

    var body: some Scene {
        WindowGroup("CaptionLab") {
            ContentView(vm: vm)
                .frame(minWidth: 1120, minHeight: 720)
                .onAppear {
                    // Preload any media path passed as a bare argument.
                    let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
                    let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !urls.isEmpty { vm.addFiles(urls) }
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
