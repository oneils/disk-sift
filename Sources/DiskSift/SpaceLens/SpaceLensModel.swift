import Foundation
import SiftCore

protocol SpaceScanning: Sendable {
    func scan(progress: (@Sendable (SpaceScanner.Progress) -> Void)?) async throws -> SpaceTree
}

extension SpaceScanner: SpaceScanning {}

/// Space Lens: one walk of the home folder, then instant drill-down. Files and folders outside the
/// large-files deny list can be moved to the Trash (`RemovalRoots.spaceLens`); `~/Library` is view-only.
@Observable
@MainActor
final class SpaceLensModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case removing
        case report(RemovalReport)
    }

    /// One row of the current folder, computed when the folder is opened.
    struct Row: Identifiable, Equatable {
        let id: Int32
        let name: String
        let kind: SpaceNode.Kind
        let size: Int64
        let inaccessible: Bool
        /// May go to the Trash (`RemovalRoots.spaceLens` allows it).
        let removable: Bool
        let url: URL
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: SpaceScanner.Progress?
    private(set) var tree: SpaceTree?
    /// The folder being shown.
    private(set) var current: Int32 = 0
    /// Children of `current`, largest first.
    private(set) var rows: [Row] = []
    /// Selected node indices (never an ancestor and a descendant together).
    private(set) var checked: Set<Int32> = []
    private(set) var selectedTotal: Int64 = 0
    private(set) var removalProgress: RemovalProgressState?
    private(set) var isStopping = false
    /// Set when "Show in Finder" hit an item that no longer exists.
    var missingItem: URL?
    let paths: SiftPaths

    private let scanner: any SpaceScanning
    private let remover: any FindingRemoving
    private let roots: RemovalRoots
    private let revealer: any FileRevealing
    private var scanTask: Task<Void, Never>?
    private var removeTask: Task<RemovalReport, Never>?
    private var removableCache: [Int32: Bool] = [:]

    init(
        scanner: any SpaceScanning, remover: any FindingRemoving, roots: RemovalRoots,
        revealer: any FileRevealing = LiveFileRevealer(), paths: SiftPaths = .live
    ) {
        self.scanner = scanner
        self.remover = remover
        self.roots = roots
        self.revealer = revealer
        self.paths = paths
    }

    static func live(paths: SiftPaths = .live) -> SpaceLensModel {
        let roots = RemovalRoots.spaceLens(paths)
        return SpaceLensModel(
            scanner: SpaceScanner(paths: paths), remover: Remover(roots: roots), roots: roots, paths: paths)
    }

    // MARK: scan

    func startScan() {
        guard phase == .idle || phase == .ready else { return }
        scanTask = Task { await scan() }
    }

    func waitForScan() async {
        await scanTask?.value
    }

    /// A stopped scan has nothing to show (the tree is complete only at the end), so it returns to the start.
    func scan() async {
        guard phase == .idle || phase == .ready else { return }
        phase = .scanning
        progress = nil
        let previous = tree
        do {
            let tree = try await scanner.scan { progress in
                Task { @MainActor in self.progress = progress }
            }
            self.tree = tree
            checked = []
            selectedTotal = 0
            removableCache = [:]
            open(0)
            phase = .ready
        } catch {
            tree = previous
            phase = previous == nil ? .idle : .ready
        }
        progress = nil
    }

    func stop() {
        scanTask?.cancel()
        stopRemove()
    }

    var hasScanned: Bool { phase != .idle }

    // MARK: navigation

    /// Shows the children of `index` (a directory).
    func open(_ index: Int32) {
        guard let tree, Int(index) < tree.nodes.count, tree[index].isEnterable else { return }
        current = index
        rows = tree.children(of: index).map { child in
            let node = tree[child]
            let url = tree.url(of: child)
            return Row(
                id: child, name: node.name, kind: node.kind, size: node.size, inaccessible: node.inaccessible,
                removable: isRemovable(child, node: node, url: url), url: url)
        }
    }

    /// Folders from the home folder down to the one shown.
    var breadcrumbs: [(index: Int32, name: String)] {
        guard let tree else { return [] }
        return tree.ancestry(of: current).map { ($0, $0 == 0 ? "~" : tree[$0].name) }
    }

    var currentSize: Int64 { tree.map { $0[current].size } ?? 0 }

    var currentInaccessible: Bool { tree.map { $0[current].inaccessible } ?? false }

    func goUp() {
        guard let tree, current != 0 else { return }
        open(tree[current].parent)
    }

    private func isRemovable(_ index: Int32, node: SpaceNode, url: URL) -> Bool {
        if case .otherFiles = node.kind { return false }
        if let cached = removableCache[index] { return cached }
        let allowed = (try? CanonicalPath.of(url)).map(roots.allows) ?? false
        removableCache[index] = allowed
        return allowed
    }

    // MARK: selection

    func isChecked(_ row: Row) -> Bool { checked.contains(row.id) }

    /// Selecting a folder drops its selected descendants; an item below a selected folder can't be selected
    /// on its own (the folder already covers it).
    func setChecked(_ row: Row, _ on: Bool) {
        guard phase == .ready, row.removable, let tree else { return }
        if on {
            guard !checked.contains(where: { $0 != row.id && tree.isAncestor($0, of: row.id) }) else { return }
            for id in checked where tree.isAncestor(row.id, of: id) { checked.remove(id) }
            checked.insert(row.id)
        } else {
            checked.remove(row.id)
        }
        selectedTotal = checked.reduce(0) { $0 + tree[$1].size }
    }

    /// The row is covered by a selected folder above it.
    func isCoveredBySelection(_ row: Row) -> Bool {
        guard let tree else { return false }
        return checked.contains { $0 != row.id && tree.isAncestor($0, of: row.id) }
    }

    var hasSelection: Bool { !checked.isEmpty }

    // MARK: removal

    func remove() async {
        guard phase == .ready, let tree, !checked.isEmpty else { return }
        let selected = checked.sorted()
        var byPath: [String: Int32] = [:]
        let findings = selected.map { index -> Finding in
            let url = tree.url(of: index)
            byPath[url.path] = index
            return Finding(url: url, size: tree[index].size, confidence: .high, sources: [.largeFile])
        }
        phase = .removing
        isStopping = false
        removalProgress = nil
        let remover = remover
        let task = Task.detached {
            await remover.remove(findings, policy: .trash) { state in
                await MainActor.run { self.removalProgress = state }
            }
        }
        removeTask = task
        let report = await task.value
        removeTask = nil
        isStopping = false
        removalProgress = nil
        var updated = tree
        var shown = current
        for item in report.removed {
            guard let index = byPath[item.url.path] else { continue }
            // the folder on screen (or one above it) is gone: go to what is left above it
            if updated.isAncestor(index, of: shown) { shown = updated[index].parent }
            updated.remove(index)
            checked.remove(index)
        }
        self.tree = updated
        selectedTotal = checked.reduce(0) { $0 + updated[$1].size }
        open(shown)
        phase = .report(report)
    }

    func stopRemove() {
        guard phase == .removing else { return }
        isStopping = true
        removeTask?.cancel()
    }

    func closeReport() {
        guard case .report = phase else { return }
        phase = .ready
    }

    func reveal(_ url: URL) {
        if !revealer.reveal(url) { missingItem = url }
    }
}
