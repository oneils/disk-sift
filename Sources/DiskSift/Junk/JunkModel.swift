import Foundation
import SiftCore

protocol JunkScanning: Sendable {
    func scan() -> AsyncStream<JunkProgress>
}

protocol FindingRemoving: Sendable {
    func remove(_ findings: [Finding], policy: RemovalPolicy) -> RemovalReport
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
        case deleting
        case report(RemovalReport)
    }

    enum CategoryState: Equatable {
        case pending
        case scanning
        case done
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

    private(set) var phase: Phase = .idle
    private(set) var rows: [Row]
    private(set) var checked: Set<String> = []
    var expanded: Set<String> = []
    var confirming = false

    private let scanner: any JunkScanning
    private let remover: any FindingRemoving
    private let categories: [any JunkCategory]
    private let runningApps: any RunningApps
    private var scanTask: Task<Void, Never>?

    init(
        scanner: any JunkScanning, remover: any FindingRemoving, categories: [any JunkCategory],
        runningApps: any RunningApps
    ) {
        self.scanner = scanner
        self.remover = remover
        self.categories = categories
        self.runningApps = runningApps
        rows = categories.map { Row(id: $0.id, title: $0.title) }
    }

    static func live(paths: SiftPaths = .live) -> JunkModel {
        let categories: [any JunkCategory] = [UserCachesCategory(), DevJunkCategory()]
        return JunkModel(
            scanner: JunkScanner(categories: categories, paths: paths),
            remover: Remover(roots: .make(paths)), categories: categories, runningApps: LiveRunningApps())
    }

    // MARK: scan

    func startScan() {
        guard phase == .idle || phase == .ready else { return }
        scanTask = Task { await scan() }
    }

    /// Cancels a running scan; what was found so far stays selectable.
    func stop() {
        scanTask?.cancel()
    }

    func waitForScan() async {
        await scanTask?.value
    }

    func scan() async {
        guard phase == .idle || phase == .ready else { return }
        phase = .scanning
        rows = categories.map { Row(id: $0.id, title: $0.title) }
        checked = []
        let running = runningApps.running()
        for await event in scanner.scan() {
            apply(event, running: running)
        }
        for index in rows.indices where rows[index].state == .scanning { rows[index].state = .done }
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
            if !finding.requiresRoot, category.checkedByDefault(finding, running: running) {
                checked.insert(finding.id)
            }
        case .categoryFinished(let id):
            update(id) { $0.state = .done }
        }
    }

    private func update(_ id: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    /// Categories finished or in progress, for the progress line.
    var finishedCount: Int { rows.filter { $0.state == .done }.count }

    // MARK: selection

    func isChecked(_ finding: Finding) -> Bool { checked.contains(finding.id) }

    func setChecked(_ finding: Finding, _ on: Bool) {
        guard !finding.requiresRoot else { return }
        if on { checked.insert(finding.id) } else { checked.remove(finding.id) }
    }

    /// Selectable (non-root) findings of a category.
    private func selectable(_ row: Row) -> [Finding] { row.findings.filter { !$0.requiresRoot } }

    func isCategoryChecked(_ row: Row) -> Bool {
        let items = selectable(row)
        return !items.isEmpty && items.allSatisfy { checked.contains($0.id) }
    }

    func setCategoryChecked(_ row: Row, _ on: Bool) {
        for finding in selectable(row) { setChecked(finding, on) }
    }

    func selectedTotal(in row: Row) -> Int64 {
        row.findings.filter { checked.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    var selectedFindings: [Finding] {
        rows.flatMap(\.findings).filter { checked.contains($0.id) && !$0.requiresRoot }
    }

    var selectedTotal: Int64 { selectedFindings.reduce(0) { $0 + ($1.size ?? 0) } }

    // MARK: delete

    func requestDelete() {
        guard phase == .ready, !selectedFindings.isEmpty else { return }
        confirming = true
    }

    func delete() async {
        confirming = false
        guard phase == .ready else { return }
        let items = selectedFindings
        guard !items.isEmpty else { return }
        phase = .deleting
        let report = remover.remove(items, policy: .delete)
        let gone = Set(report.removed.map { $0.url.standardizedFileURL.path })
        for index in rows.indices {
            rows[index].findings.removeAll { gone.contains($0.url.standardizedFileURL.path) }
        }
        checked = checked.filter { !gone.contains($0) }
        phase = .report(report)
    }

    func closeReport() {
        guard case .report = phase else { return }
        phase = .ready
    }
}
