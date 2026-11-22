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
    private(set) var groups: [OrphanGroup] = []
    private(set) var checked: Set<String> = []
    var sort: ResultSort = .size
    private(set) var isStopping = false
    private(set) var removalProgress: RemovalProgressState?
    /// Set when "Show in Finder" hit an item that no longer exists.
    var missingItem: URL?
    let paths: SiftPaths

    private let scanner: any OrphanScanning
    private let remover: any OrphanRemoving
    private let revealer: any FileRevealing
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
        checked = []
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
        checked = []
    }

    // MARK: list

    var sortedGroups: [OrphanGroup] {
        sort.sorted(groups, size: \.totalSize, name: \.id)
    }

    var foundTotal: Int64 { groups.reduce(0) { $0 + $1.totalSize } }

    var foundCount: Int { groups.reduce(0) { $0 + $1.findings.count } }

    // MARK: selection (nothing preselected; root-only items are shown but never selectable)

    func isChecked(_ finding: Finding) -> Bool { checked.contains(finding.id) }

    func setChecked(_ finding: Finding, _ on: Bool) {
        guard phase == .results, !finding.requiresRoot else { return }
        if on { checked.insert(finding.id) } else { checked.remove(finding.id) }
    }

    private func selectable(_ group: OrphanGroup) -> [Finding] { group.findings.filter { !$0.requiresRoot } }

    func groupState(_ group: OrphanGroup) -> JunkModel.CheckState {
        let items = selectable(group)
        let on = items.filter { checked.contains($0.id) }.count
        if on == 0 { return .off }
        return on == items.count ? .on : .mixed
    }

    func hasSelectable(_ group: OrphanGroup) -> Bool { !selectable(group).isEmpty }

    func setGroup(_ group: OrphanGroup, _ on: Bool) {
        for finding in selectable(group) { setChecked(finding, on) }
    }

    var selectedFindings: [Finding] {
        groups.flatMap(\.findings).filter { checked.contains($0.id) && !$0.requiresRoot }
    }

    var selectedTotal: Int64 { selectedFindings.reduce(0) { $0 + ($1.size ?? 0) } }

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
        groups = groups.compactMap { group in
            let left = group.findings.filter { !gone.contains($0.id) }
            return left.isEmpty ? nil : OrphanGroup(id: group.id, findings: left)
        }
        checked.subtract(gone)
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
