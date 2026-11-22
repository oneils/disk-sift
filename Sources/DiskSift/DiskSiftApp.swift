import AppKit
import SwiftUI

@main
struct DiskSiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let shell = ShellModel()

    var body: some Scene {
        WindowGroup("DiskSift") {
            ContentView(model: shell)
        }
        .defaultSize(width: 900, height: 620)
    }

    /// True when the executable lives inside an `.app` bundle (false for `swift run`).
    nonisolated static func isBundled(_ bundleURL: URL) -> Bool {
        bundleURL.pathExtension == "app"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // a bare executable starts as a background process: make it a regular app with a Dock icon
        // and bring the window to front
        guard !DiskSiftApp.isBundled(Bundle.main.bundleURL) else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
