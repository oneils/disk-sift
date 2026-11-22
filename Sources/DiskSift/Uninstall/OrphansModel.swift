import Foundation
import SiftCore

protocol OrphanScanning: Sendable {
    func scan() async throws -> [OrphanGroup]
}

protocol OrphanRemoving: Sendable {
    func remove(
        _ findings: [Finding], onProgress: (@Sendable (RemovalProgressState) async -> Void)?
    ) async -> RemovalReport
}

extension OrphanScanner: OrphanScanning {}
extension OrphanRemover: OrphanRemoving {}

/// Leftovers of apps that are no longer installed: scan, review (nothing preselected), move to the Trash.
/// One finding as the list shows it, computed once per scan or removal instead of on every redraw.
struct OrphanRowData: Identifiable, Equatable {
    let id: String
    let finding: Finding
    let name: String
    /// English localization key of the location kind ("Caches").
    let kindKey: String
    /// Parent folder with `~` for the home directory.
    let parentPath: String
    let evidenceKeys: [String]
}

/// One app's leftovers as the list shows it.
struct OrphanSection: Identifiable, Equatable {
    let group: OrphanGroup
    let rows: [OrphanRowData]
    let totalSize: Int64
    /// IDs of findings that can be selected (not root-owned).
    let selectableIDs: [String]

    var id: String { group.id }
}

/// Leftovers of apps that are no longer installed: scan, review (nothing preselected), move to the Trash.
/// The list can hold thousands of rows, so everything a row or header shows is precomputed and the
/// selection totals are kept up to date instead of being recomputed on every redraw.
@Observable
@MainActor
final class OrphansModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case removing
        case report(RemovalReport)
    }

    private(set) var phase: Phase = .idle
    /// Largest first, as scanned; `sortedGroups` applies `sort`.
    private(set) var groups: [OrphanGroup] = [] {
        didSet { rebuild() }
    }
    /// `groups` in `sort` order with precomputed rows.
    private(set) var sortedGroups: [OrphanSection] = []
    private(set) var foundTotal: Int64 = 0
    private(set) var foundCount = 0
    /// Selected finding IDs; the single source of truth for the selection.
    private(set) var checked: Set<String> = []
    /// Bytes of the selected findings, kept in step with `checked`.
    private(set) var selectedTotal: Int64 = 0
    /// Selected findings per group ID, kept in step with `checked`.
    private var selectedCount: [String: Int] = [:]
    var sort: ResultSort = .size {
        didSet { if sort != oldValue { sortSections() } }
    }
    private(set) var isStopping = false
    private(set) var removalProgress: RemovalProgressState?
    /// Set when "Show in Finder" hit an item that no longer exists.
    var missingItem: URL?
    let paths: SiftPaths

    private let scanner: any OrphanScanning
    private let remover: any OrphanRemoving
    private let revealer: any FileRevealing
    private let locations: LocationKindResolver
    /// Finding ID -> (group ID, size, selectable), for O(1) selection updates.
    private var index: [String: (group: String, size: Int64, selectable: Bool)] = [:]
    private var scanTask: Task<Void, Never>?
    private var removeTask: Task<RemovalReport, Never>?

    init(
        scanner: any OrphanScanning, remover: any OrphanRemoving, revealer: any FileRevealing = LiveFileRevealer(),
        paths: SiftPaths = .live
    ) {
        self.scanner = scanner
        self.remover = remover
        self.revealer = revealer
        self.paths = paths
        locations = LocationKindResolver(paths: paths)
    }

    static func live(paths: SiftPaths = .live) -> OrphansModel {
        OrphansModel(
            scanner: OrphanScanner(paths: paths, installed: LiveInstalledApps(), runningApps: LiveRunningApps()),
            remover: OrphanRemover(remover: Remover(roots: .make(paths)), runner: ProcessCommandRunner()),
            paths: paths)
    }

    // MARK: scan

    func startScan() {
        guard phase == .idle || phase == .results else { return }
        scanTask = Task { await scan() }
    }

    func waitForScan() async {
        await scanTask?.value
    }

    /// A stopped scan has nothing to show (results arrive at the end), so it returns to the start.
    func scan() async {
        guard phase == .idle || phase == .results else { return }
        phase = .scanning
        groups = []
        clearSelection()
        do {
            groups = try await scanner.scan()
            phase = Task.isCancelled ? .idle : .results
        } catch {
            groups = []
            phase = .idle
        }
    }

    func stop() {
        scanTask?.cancel()
        stopRemove()
    }

    /// Back to the uninstall start screen.
    func close() {
        guard phase != .removing && phase != .scanning else { return }
        phase = .idle
        groups = []
        clearSelection()
    }

    // MARK: list

    private func rebuild() {
        var index: [String: (group: String, size: Int64, selectable: Bool)] = [:]
        var sections: [OrphanSection] = []
        sections.reserveCapacity(groups.count)
        for group in groups {
            var rows: [OrphanRowData] = []
            rows.reserveCapacity(group.findings.count)
            for finding in group.findings {
                let id = finding.id
                let parent = finding.url.deletingLastPathComponent()
                rows.append(
                    OrphanRowData(
                        id: id, finding: finding, name: finding.url.lastPathComponent,
                        kindKey: locations.kind(of: parent).titleKey, parentPath: paths.displayPath(parent),
                        evidenceKeys: finding.evidenceKeys))
                index[id] = (group.id, finding.size ?? 0, !finding.requiresRoot)
            }
            sections.append(
                OrphanSection(
                    group: group, rows: rows, totalSize: group.totalSize,
                    selectableIDs: group.findings.filter { !$0.requiresRoot }.map(\.id)))
        }
        self.index = index
        foundTotal = sections.reduce(0) { $0 + $1.totalSize }
        foundCount = index.count
        sortedGroups = sections
        sortSections()
        // drop selection of findings that are gone
        let stale = checked.filter { index[$0] == nil }
        if !stale.isEmpty { for id in stale { setChecked(id: id, false) } }
    }

    private func sortSections() {
        sortedGroups = sort.sorted(sortedGroups, size: \.totalSize, name: \.id)
    }

    // MARK: selection (nothing preselected; root-only items are shown but never selectable)

    func isChecked(_ finding: Finding) -> Bool { checked.contains(finding.id) }

    func isChecked(id: String) -> Bool { checked.contains(id) }

    func setChecked(_ finding: Finding, _ on: Bool) {
        guard phase == .results else { return }
        setChecked(id: finding.id, on)
    }

    /// Updates `checked` and the totals derived from it together.
    private func setChecked(id: String, _ on: Bool) {
        if on {
            guard let entry = index[id], entry.selectable, checked.insert(id).inserted else { return }
            selectedTotal += entry.size
            selectedCount[entry.group, default: 0] += 1
        } else {
            guard checked.remove(id) != nil else { return }
            if let entry = index[id] {
                selectedTotal -= entry.size
                selectedCount[entry.group, default: 0] -= 1
            } else {
                recomputeTotals()
            }
        }
    }

    private func clearSelection() {
        checked = []
        selectedTotal = 0
        selectedCount = [:]
    }

    private func recomputeTotals() {
        selectedTotal = 0
        selectedCount = [:]
        for id in checked {
            guard let entry = index[id] else { continue }
            selectedTotal += entry.size
            selectedCount[entry.group, default: 0] += 1
        }
    }

    private func selectableCount(_ groupID: String) -> Int {
        sortedGroups.first { $0.id == groupID }?.selectableIDs.count ?? 0
    }

    func groupState(_ group: OrphanGroup) -> JunkModel.CheckState { groupState(id: group.id) }

    func groupState(_ section: OrphanSection) -> JunkModel.CheckState {
        state(on: selectedCount[section.id] ?? 0, of: section.selectableIDs.count)
    }

    private func groupState(id: String) -> JunkModel.CheckState {
        state(on: selectedCount[id] ?? 0, of: selectableCount(id))
    }

    private func state(on: Int, of total: Int) -> JunkModel.CheckState {
        if on == 0 { return .off }
        return on >= total ? .on : .mixed
    }

    func hasSelectable(_ group: OrphanGroup) -> Bool { group.findings.contains { !$0.requiresRoot } }

    func setGroup(_ group: OrphanGroup, _ on: Bool) {
        guard phase == .results else { return }
        for finding in group.findings where !finding.requiresRoot { setChecked(id: finding.id, on) }
    }

    func setGroup(_ section: OrphanSection, _ on: Bool) {
        guard phase == .results else { return }
        for id in section.selectableIDs { setChecked(id: id, on) }
    }

    var hasSelection: Bool { !checked.isEmpty }

    /// Selected findings in scan order; built only when needed (removal, tests), not on redraws.
    var selectedFindings: [Finding] {
        groups.flatMap(\.findings).filter { checked.contains($0.id) && !$0.requiresRoot }
    }

    // MARK: removal

    func remove() async {
        guard phase == .results else { return }
        let items = selectedFindings
        guard !items.isEmpty else { return }
        phase = .removing
        isStopping = false
        removalProgress = nil
        let remover = remover
        let task = Task.detached {
            await remover.remove(items) { state in
                await MainActor.run { self.removalProgress = state }
            }
        }
        removeTask = task
        let report = await task.value
        removeTask = nil
        isStopping = false
        removalProgress = nil
        let gone = Set(report.removed.map(\.url.path))
        for id in gone { setChecked(id: id, false) }
        groups = groups.compactMap { group in
            let left = group.findings.filter { !gone.contains($0.id) }
            return left.isEmpty ? nil : OrphanGroup(id: group.id, findings: left)
        }
        phase = .report(report)
    }

    func stopRemove() {
        guard phase == .removing else { return }
        isStopping = true
        removeTask?.cancel()
    }

    func closeReport() {
        guard case .report = phase else { return }
        phase = .results
    }

    func reveal(_ url: URL) {
        if !revealer.reveal(url) { missingItem = url }
    }
}
