import AppKit
import SiftCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case uninstall = "Uninstall"
    case junk = "Junk"

    var id: String { rawValue }
    var icon: String { self == .uninstall ? "trash" : "sparkles" }
}

/// Window-level state. An `@Observable` class instead of `@State`: the SwiftUI macro plugin
/// is missing from Command Line Tools-only toolchains.
@Observable
@MainActor
final class ShellModel {
    var selection: Section? = .uninstall
    var fdaGranted = true
    let uninstall: UninstallModel
    let junk: JunkModel

    init(uninstall: UninstallModel = .live(), junk: JunkModel = .live()) {
        self.uninstall = uninstall
        self.junk = junk
    }

    func refreshFDA() {
        fdaGranted = FullDiskAccess.isGranted(.live)
    }
}

struct ContentView: View {
    @Bindable var model: ShellModel

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $model.selection) { section in
                Label(LocalizedStringKey(section.rawValue), systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } detail: {
            VStack(spacing: 0) {
                if !model.fdaGranted { FDABanner() }
                switch model.selection ?? .uninstall {
                case .uninstall:
                    UninstallView(model: model.uninstall)
                case .junk:
                    JunkView(model: model.junk)
                }
            }
            .navigationTitle(LocalizedStringKey((model.selection ?? .uninstall).rawValue))
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { model.refreshFDA() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFDA()
        }
    }
}
