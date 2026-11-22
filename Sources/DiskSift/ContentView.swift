import AppKit
import SiftCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case uninstall = "Uninstall"
    case junk = "Junk"
    case largeFiles = "Large Files"
    case plugins = "Plugins"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .uninstall: "trash"
        case .junk: "sparkles"
        case .largeFiles: "doc.text.magnifyingglass"
        case .plugins: "pianokeys"
        }
    }
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
    let largeFiles: LargeFilesModel
    let orphans: OrphansModel
    let plugins: PluginsModel

    init(
        uninstall: UninstallModel = .live(), junk: JunkModel = .live(), largeFiles: LargeFilesModel = .live(),
        orphans: OrphansModel = .live(), plugins: PluginsModel = .live()
    ) {
        self.plugins = plugins
        self.uninstall = uninstall
        self.junk = junk
        self.largeFiles = largeFiles
        self.orphans = orphans
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
                    if model.orphans.phase != .idle {
                        OrphansView(model: model.orphans, fdaGranted: model.fdaGranted)
                    } else {
                        UninstallView(model: model.uninstall) { model.orphans.startScan() }
                    }
                case .junk:
                    JunkView(model: model.junk)
                case .largeFiles:
                    LargeFilesView(model: model.largeFiles)
                case .plugins:
                    PluginsView(model: model.plugins)
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
