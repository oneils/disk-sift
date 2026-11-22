import AppKit
import SiftCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case uninstall = "Uninstall"
    case junk = "Junk"
    case largeFiles = "Large Files"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .uninstall: "trash"
        case .junk: "sparkles"
        case .largeFiles: "doc.text.magnifyingglass"
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

    init(
        uninstall: UninstallModel = .live(), junk: JunkModel = .live(), largeFiles: LargeFilesModel = .live()
    ) {
        self.uninstall = uninstall
        self.junk = junk
        self.largeFiles = largeFiles
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
                case .largeFiles:
                    LargeFilesView(model: model.largeFiles)
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
