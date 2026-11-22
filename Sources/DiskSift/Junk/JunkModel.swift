import Foundation
import SiftCore

protocol JunkScanning: Sendable {
    func scan() -> AsyncStream<JunkProgress>
}

protocol FindingRemoving: Sendable {
    func remove(
        _ findings: [Finding],
        policy: RemovalPolicy,
        onProgress: (@Sendable (RemovalProgressState) async -> Void)?
    ) async -> RemovalReport
    func remove(_ findings: [Finding], policy: RemovalPolicy) -> RemovalReport
}

protocol ChildListing: Sendable {
    func children(of url: URL) async throws -> [DirectoryChild]
}

struct LiveChildLister: ChildListing {
    func children(of url: URL) async throws -> [DirectoryChild] { try await DirectoryChildren.list(of: url) }
}

extension JunkScanner: JunkScanning {}
extension Remover: FindingRemoving {}

@Observable
@MainActor
final class JunkModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case removing
        case report(RemovalReport)
    }

    enum CategoryState: Equatable {
        case pending
        case scanning
        case done
        /// The scan was stopped before this category finished; its findings are incomplete.
        case stopped
        /// The category's location exists but can't be read (usually no Full Disk Access).
        case noAccess
    }

    struct Row: Identifiable, Equatable {
        var id: String
        /// English localization key.
        var title: String
        var state: CategoryState = .pending
        /// Largest first.
        var findings: [Finding] = []

        var total: Int64 { findings.reduce(0) { $0 + ($1.size ?? 0) } }
    }

    enum CheckState: Equatable {
        case off
        case on
        case mixed
    }

    /// A row below a finding. Findings themselves are depth 0.
    struct Node: Identifiable, Equatable {
        var id: String { url.path }
        var url: URL
        var size: Int64
        var parentID: String
        var categoryID: String
        var depth: Int
        var isDirectory: Bool
        var inaccessible: Bool
        /// Shown instead of the file name when set (iOS backups).
        var displayName: String?

        var title: String { displayName ?? url.lastPathComponent }
    }

    /// Levels that can be expanded below a finding.
    static let maxDepth = 2

    private(set) var phase: Phase = .idle
    private(set) var rows: [Row]
    private(set) var checked: Set<String> = []
    var expanded: Set<String> = []
    /// Expanded findings and children, by path.
    private(set) var expandedNodes: Set<String> = []
    /// Paths whose children are being listed.
    private(set) var loading: Set<String> = []
    private var nodes: [String: Node] = [:]
    /// Loaded children by parent path, largest first.
    private var childrenByParent: [String: [String]] = [:]
    private var generation = 0
    /// Findings known to be regular files (nothing to expand).
    private var plainFiles: Set<String> = []
    var confirming = false
    /// The last scan was stopped before every category finished.
    private(set) var scanStopped = false
    var sort: ResultSort = .size
    /// Set when "Show in Finder" hit an item that no longer exists.
    var missingItem: URL?

    private let scanner: any JunkScanning
    /// `RemovalRoots.make`: caches, logs, dev caches, Mail downloads (delete) and iOS backups (trash).
    private let remover: any FindingRemoving
    /// `RemovalRoots.largeFiles`: installers (files only, Trash only).
    private let largeFilesRemover: any FindingRemoving
    private let categories: [any JunkCategory]
    private let runningApps: any RunningApps
    private let lister: any ChildListing
    private let revealer: any FileRevealing
    let paths: SiftPaths
    private(set) var isStopping = false
    private(set) var removalProgress: RemovalProgressState?
    private var scanTask: Task<Void, Never>?
    private var removeTask: Task<(RemovalReport, [RemovalPolicy: [RemovedItem]]), Never>?

    init(
        scanner: any JunkScanning, remover: any FindingRemoving, largeFilesRemover: (any FindingRemoving)? = nil,
        categories: [any JunkCategory],
        runningApps: any RunningApps, lister: any ChildListing = LiveChildLister(),
        revealer: any FileRevealing = LiveFileRevealer(), paths: SiftPaths = .live
    ) {
        self.paths = paths
        self.lister = lister
        self.revealer = revealer
        self.scanner = scanner
        self.remover = remover
        // without a dedicated remover, large-files items go to the library one, which refuses them (outside roots)
        self.largeFilesRemover = largeFilesRemover ?? remover
        self.categories = categories
        self.runningApps = runningApps
        rows = categories.map { Row(id: $0.id, title: $0.title) }
    }

    static func live(paths: SiftPaths = .live) -> JunkModel {
        let categories: [any JunkCategory] = [
            UserCachesCategory(), DevJunkCategory(), InstallersCategory(), IOSBackupsCategory(),
            MailDownloadsCategory(),
        ]
        return JunkModel(
            scanner: JunkScanner(categories: categories, paths: paths),
            remover: Remover(roots: .make(paths)), largeFilesRemover: Remover(roots: .largeFiles(paths)),
            categories: categories, runningApps: LiveRunningApps(),
            paths: paths)
    }

    // MARK: scan

    func startScan() {
        guard phase == .idle || phase == .ready else { return }
        scanTask = Task { await scan() }
    }

    /// Cancels a running scan or deletion; what was found or deleted so far stays.
    func stop() {
        scanTask?.cancel()
        stopRemove()
    }

    func stopRemove() {
        guard phase == .removing else { return }
        isStopping = true
        removeTask?.cancel()
    }

    func waitForScan() async {
        await scanTask?.value
    }

    func scan() async {
        guard phase == .idle || phase == .ready else { return }
        phase = .scanning
        scanStopped = false
        rows = categories.map { Row(id: $0.id, title: $0.title) }
        checked = []
        resetTree()
        plainFiles = []
        let running = runningApps.running()
        for await event in scanner.scan() {
            apply(event, running: running)
        }
        // the stream ends early only when cancelled; unfinished categories are then incomplete, not empty
        let cancelled = Task.isCancelled
        for index in rows.indices where rows[index].state != .done && rows[index].state != .noAccess {
            if cancelled {
                rows[index].state = .stopped
            } else if rows[index].state == .scanning {
                rows[index].state = .done
            }
        }
        scanStopped = cancelled && rows.contains { $0.state == .stopped }
        phase = .ready
    }

    private func apply(_ event: JunkProgress, running: [RunningApp]) {
        switch event {
        case .categoryStarted(let id):
            update(id) { $0.state = .scanning }
        case .findingSized(let id, let finding):
            guard let category = categories.first(where: { $0.id == id }) else { return }
            update(id) {
                $0.findings.append(finding)
                $0.findings.sort { ($0.size ?? 0) > ($1.size ?? 0) }
            }
            var st = stat()
            if lstat(finding.url.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR { plainFiles.insert(finding.id) }
            if !finding.requiresRoot, category.checkedByDefault(finding, running: running) {
                checked.insert(finding.id)
            }
        case .categoryFinished(let id):
            // never hide a "no access" result behind a finished (and empty-looking) category
            update(id) { if $0.state != .noAccess { $0.state = .done } }
        case .categoryUnreadable(let id):
            update(id) { $0.state = .noAccess }
        }
    }

    private func update(_ id: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    /// Categories finished or in progress, for the progress line.
    var finishedCount: Int { rows.filter { $0.state == .done }.count }

    /// A scan has run (or is running); before that nothing is known about any location.
    var hasScanned: Bool { phase != .idle }

    /// Everything found, across categories (they never overlap).
    var foundTotal: Int64 { rows.reduce(0) { $0 + $1.total } }

    var foundCount: Int { rows.reduce(0) { $0 + $1.findings.count } }

    /// A complete scan found nothing.
    var foundNothing: Bool { phase == .ready && !scanStopped && foundCount == 0 }

    /// Findings of a row in the current sort order.
    func sortedFindings(_ row: Row) -> [Finding] {
        sort.sorted(row.findings, size: { $0.size ?? 0 }, name: { $0.url.lastPathComponent })
    }

    /// Loaded children in the current sort order.
    func sortedChildren(of id: String) -> [Node] {
        sort.sorted(children(of: id), size: \.size, name: { $0.url.lastPathComponent })
    }

    // MARK: inspect

    func reveal(_ url: URL) {
        if !revealer.reveal(url) { missingItem = url }
    }

    // MARK: tree

    private func resetTree() {
        generation += 1
        expandedNodes = []
        loading = []
        nodes = [:]
        childrenByParent = [:]
    }

    private func finding(withID id: String) -> Finding? {
        for row in rows { if let found = row.findings.first(where: { $0.id == id }) { return found } }
        return nil
    }

    /// The node for a finding or a loaded child.
    func node(for finding: Finding, categoryID: String) -> Node {
        Node(
            url: finding.url, size: finding.size ?? 0, parentID: "", categoryID: categoryID, depth: 0,
            isDirectory: !plainFiles.contains(finding.id), inaccessible: finding.inaccessible,
            displayName: finding.displayName)
    }

    func canExpand(_ node: Node, requiresRoot: Bool = false) -> Bool {
        node.isDirectory && node.depth < Self.maxDepth && !requiresRoot && isExpandable(node.categoryID)
    }

    private func isExpandable(_ categoryID: String) -> Bool {
        categories.first { $0.id == categoryID }?.expandable ?? true
    }

    func children(of id: String) -> [Node] { (childrenByParent[id] ?? []).compactMap { nodes[$0] } }

    func isExpanded(_ id: String) -> Bool { expandedNodes.contains(id) }

    func isLoading(_ id: String) -> Bool { loading.contains(id) }

    func setExpanded(_ node: Node, _ on: Bool) {
        if on {
            Task { await expand(node) }
        } else {
            expandedNodes.remove(node.id)
        }
    }

    /// Lists and sizes the children on first expansion; later expansions reuse them.
    func expand(_ node: Node) async {
        let id = node.id
        guard node.isDirectory, node.depth < Self.maxDepth else { return }
        expandedNodes.insert(id)
        guard childrenByParent[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        let started = generation
        let listed: [DirectoryChild]?
        do { listed = try await lister.children(of: node.url) } catch { listed = nil }
        guard started == generation else { return }
        loading.remove(id)
        guard let listed else {
            expandedNodes.remove(id)
            return
        }
        let loaded = listed.sorted { $0.size > $1.size }.map {
            Node(
                url: $0.url, size: $0.size, parentID: id, categoryID: node.categoryID, depth: node.depth + 1,
                isDirectory: $0.kind == .directory, inaccessible: $0.inaccessible)
        }
        childrenByParent[id] = loaded.map(\.id)
        let inherit = checked.contains(id)
        for child in loaded {
            nodes[child.id] = child
            if inherit { checked.insert(child.id) }
        }
    }

    // MARK: selection

    /// Invariant: `checked` holds the fully checked items; an item with loaded children is in it
    /// exactly when all of them are. Mixed is derived from the descendants.
    func state(of id: String) -> CheckState {
        if checked.contains(id) { return .on }
        return children(of: id).contains { state(of: $0.id) != .off } ? .mixed : .off
    }

    func isChecked(_ finding: Finding) -> Bool { checked.contains(finding.id) }

    func setChecked(_ finding: Finding, _ on: Bool) {
        guard !finding.requiresRoot else { return }
        setChecked(id: finding.id, on)
    }

    /// Sets an item and everything loaded below it, then refreshes its ancestors.
    func setChecked(id: String, _ on: Bool) {
        guard phase != .removing else { return }
        setSubtree(id, on)
        var parent = nodes[id]?.parentID
        while let current = parent, !current.isEmpty {
            let kids = children(of: current)
            if !kids.isEmpty && kids.allSatisfy({ checked.contains($0.id) }) {
                checked.insert(current)
            } else {
                checked.remove(current)
            }
            parent = nodes[current]?.parentID
        }
    }

    private func setSubtree(_ id: String, _ on: Bool) {
        if on { checked.insert(id) } else { checked.remove(id) }
        for child in children(of: id) { setSubtree(child.id, on) }
    }

    /// Selectable (non-root) findings of a category.
    private func selectable(_ row: Row) -> [Finding] { row.findings.filter { !$0.requiresRoot } }

    func isCategoryChecked(_ row: Row) -> Bool {
        let items = selectable(row)
        return !items.isEmpty && items.allSatisfy { checked.contains($0.id) }
    }

    /// Tri-state for a category: mixed when some (or part of some) findings are selected.
    func categoryState(_ row: Row) -> CheckState {
        if isCategoryChecked(row) { return .on }
        return selectable(row).contains { state(of: $0.id) != .off } ? .mixed : .off
    }

    func hasSelectable(_ row: Row) -> Bool { !selectable(row).isEmpty }

    func setCategoryChecked(_ row: Row, _ on: Bool) {
        for finding in selectable(row) { setChecked(finding, on) }
    }

    func selectedTotal(in row: Row) -> Int64 {
        selection(of: row).reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// What deletion removes for a row: a fully checked item as a whole, otherwise only its checked descendants.
    private func selection(of row: Row) -> [Finding] {
        var result: [Finding] = []
        func collect(_ id: String, _ make: () -> Finding?) {
            if checked.contains(id) {
                if let item = make() { result.append(item) }
                return
            }
            for child in children(of: id) {
                collect(child.id) {
                    Finding(
                        url: child.url, size: child.size, confidence: .high,
                        sources: [.junk(categoryID: child.categoryID)], inaccessible: child.inaccessible)
                }
            }
        }
        for item in row.findings where !item.requiresRoot { collect(item.id) { item } }
        return result
    }

    var selectedFindings: [Finding] {
        FindingMerger.merge(rows.flatMap { selection(of: $0) })
    }

    var selectedTotal: Int64 { selectedFindings.reduce(0) { $0 + ($1.size ?? 0) } }

    // MARK: removal

    /// One remover call: items of categories that share a removal scope and policy.
    struct Batch {
        var scope: JunkRemovalScope
        var policy: RemovalPolicy
        var items: [Finding]
    }

    /// Selected items grouped by their category's scope and policy: permanent deletion first, then the
    /// Trash (library), then installers. Never decided by category ID, only by what the category declares.
    func batches(_ items: [Finding]) -> [Batch] {
        let order: [(JunkRemovalScope, RemovalPolicy)] = [
            (.library, .delete), (.library, .trash), (.largeFiles, .trash),
        ]
        var grouped: [Int: [Finding]] = [:]
        for item in items {
            guard let category = category(of: item) else { continue }
            let key = (category.removalScope, category.policy)
            guard let index = order.firstIndex(where: { $0 == key }) else { continue }
            grouped[index, default: []].append(item)
        }
        return order.indices.compactMap { index in
            grouped[index].map { Batch(scope: order[index].0, policy: order[index].1, items: $0) }
        }
    }

    private func category(of finding: Finding) -> (any JunkCategory)? {
        for case .junk(let id) in finding.sources {
            if let category = categories.first(where: { $0.id == id }) { return category }
        }
        return nil
    }

    private func total(_ policy: RemovalPolicy) -> Int64 {
        batches(selectedFindings).filter { $0.policy == policy }.flatMap(\.items).reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// Selected bytes that will be deleted permanently.
    var selectedDeleteTotal: Int64 { total(.delete) }

    /// Selected bytes that will be moved to the Trash.
    var selectedTrashTotal: Int64 { total(.trash) }

    /// What the last removal did per policy, for the report.
    private(set) var lastRemoved: [RemovalPolicy: [RemovedItem]] = [:]

    func requestRemove() {
        guard phase == .ready, !selectedFindings.isEmpty else { return }
        confirming = true
    }

    func remove() async {
        confirming = false
        guard phase == .ready else { return }
        let batches = batches(selectedFindings)
        guard !batches.isEmpty else { return }
        phase = .removing
        isStopping = false
        removalProgress = nil
        let removers: [JunkRemovalScope: any FindingRemoving] = [.library: remover, .largeFiles: largeFilesRemover]
        // removing large trees (DerivedData) must not block the main actor
        let task = Task.detached {
            await Self.run(batches, removers: removers) { state in
                await MainActor.run { self.removalProgress = state }
            }
        }
        removeTask = task
        let (report, byPolicy) = await task.value
        isStopping = false
        removeTask = nil
        removalProgress = nil
        lastRemoved = byPolicy
        let gone = Set(report.removed.map { $0.url.standardizedFileURL.path })
        pruneRemoved(
            gone,
            sizes: Dictionary(
                report.removed.map { ($0.url.standardizedFileURL.path, $0.size ?? 0) }, uniquingKeysWith: max))
        phase = .report(report)
    }

    /// Runs batches in order with one combined progress; once stopped, later batches are left unprocessed.
    nonisolated private static func run(
        _ batches: [Batch], removers: [JunkRemovalScope: any FindingRemoving],
        onProgress: @escaping @Sendable (RemovalProgressState) async -> Void
    ) async -> (RemovalReport, [RemovalPolicy: [RemovedItem]]) {
        let total = batches.reduce(0) { $0 + $1.items.count }
        var combined = RemovalReport()
        var byPolicy: [RemovalPolicy: [RemovedItem]] = [:]
        var done = 0
        var bytes: Int64 = 0
        for batch in batches {
            if Task.isCancelled || combined.stopped {
                combined.stopped = true
                combined.unprocessed += batch.items
                continue
            }
            guard let remover = removers[batch.scope] else { continue }
            let (offset, base) = (done, bytes)
            let report = await remover.remove(batch.items, policy: batch.policy) { state in
                await onProgress(
                    RemovalProgressState(
                        current: state.current, completed: offset + state.completed, total: total,
                        processedBytes: base + state.processedBytes))
            }
            combined.removed += report.removed
            combined.skipped += report.skipped
            combined.unprocessed += report.unprocessed
            combined.stopped = combined.stopped || report.stopped
            byPolicy[batch.policy, default: []] += report.removed
            done += batch.items.count - report.unprocessed.count
            bytes += report.removed.reduce(0) { $0 + ($1.size ?? 0) }
        }
        if combined.unprocessed.isEmpty { combined.stopped = false }
        return (combined, byPolicy)
    }

    func closeReport() {
        guard case .report = phase else { return }
        phase = .ready
    }

    /// Drops removed items (and anything below them) and shrinks the sizes of their remaining ancestors.
    private func pruneRemoved(_ gone: Set<String>, sizes: [String: Int64]) {
        func isGone(_ path: String) -> Bool {
            gone.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        // ancestors of a removed child lose its size (removed parents are dropped entirely)
        for path in gone {
            guard let node = nodes[path], !isGone(node.parentID) else { continue }
            let size = sizes[path] ?? node.size
            var parent: String? = node.parentID
            while let current = parent, !current.isEmpty {
                if var n = nodes[current] {
                    n.size = max(0, n.size - size)
                    nodes[current] = n
                    parent = n.parentID
                } else {
                    parent = nil
                }
                for index in rows.indices {
                    if let at = rows[index].findings.firstIndex(where: { $0.id == current }) {
                        rows[index].findings[at].size = max(0, (rows[index].findings[at].size ?? 0) - size)
                    }
                }
            }
        }
        for index in rows.indices {
            rows[index].findings.removeAll { gone.contains($0.url.standardizedFileURL.path) }
        }
        for (id, node) in nodes where isGone(id) { nodes[node.id] = nil }
        for (parent, kids) in childrenByParent {
            if isGone(parent) {
                childrenByParent[parent] = nil
            } else {
                childrenByParent[parent] = kids.filter { !isGone($0) }
            }
        }
        checked = checked.filter { !isGone($0) }
        expandedNodes = expandedNodes.filter { !isGone($0) }
    }
}
