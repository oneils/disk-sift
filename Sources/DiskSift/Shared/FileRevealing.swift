import AppKit
import Foundation

/// Shows an item in Finder (live: NSWorkspace).
protocol FileRevealing: Sendable {
    /// False when the item no longer exists; nothing is shown then.
    @MainActor func reveal(_ url: URL) -> Bool
}

struct LiveFileRevealer: FileRevealing {
    @MainActor func reveal(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}

/// Order of comparable siblings in a results list. Selection is keyed by path, so re-sorting never changes it.
enum ResultSort: String, CaseIterable, Identifiable {
    case size
    case name

    var id: String { rawValue }

    /// English localization key.
    var titleKey: String { self == .size ? "Size" : "Name" }

    func sorted<T>(_ items: [T], size: (T) -> Int64, name: (T) -> String) -> [T] {
        switch self {
        case .size:
            items.sorted {
                let (l, r) = (size($0), size($1))
                return l != r ? l > r : name($0).localizedStandardCompare(name($1)) == .orderedAscending
            }
        case .name:
            items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        }
    }
}
