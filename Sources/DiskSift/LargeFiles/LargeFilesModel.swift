import Foundation
import SiftCore

protocol LargeFileScanning: Sendable {
    func scan() -> AsyncStream<LargeFileProgress>
}

extension LargeFileScanner: LargeFileScanning {}

/// Order of the Large Files list. Local to this tab: "date" means nothing for junk or leftovers.
enum LargeFileSort: String, CaseIterable, Identifiable {
    case size
    case name
    case date

    var id: String { rawValue }

    /// English localization key.
    var titleKey: String {
        switch self {
        case .size: "Size"
        case .name: "Name"
        case .date: "Date"
        }
    }
}

@Observable
@MainActor
final class LargeFilesModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case trashing
        case report(RemovalReport)
    }

    struct Row: Identifiable, Equatable {
        var file: LargeFile
        /// From Spotlight; nil when unknown, then the modification date is shown instead.
        var lastOpened: Date?

        var id: String { file.id }

        /// The date shown and sorted by, and whether it is a last-opened date (else "modified").
        var shownDate: (date: Date?, isOpened: Bool) {
            lastOpened.map { ($0, true) } ?? (file.modified, false)
        }
    }

    /// Thresholds offered in the UI, decimal like every displayed size; the scan collects from the smallest.
    static let thresholds: [Int64] = [100_000_000, 500_000_000, 1_000_000_000, 5_000_000_000]
    static let defaultThreshold: Int64 = 500_000_000

    private(set) var phase: Phase = .idle
    /// Everything found (at least the smallest threshold), in discovery order.
    private(set) var rows: [Row] = []
    var threshold: Int64 = LargeFilesModel.defaultThreshold
    var sort: LargeFileSort = .size
    private(set) var checked: Set<String> = []
    /// The last scan was stopped before the walk completed.
    private(set) var scanStopped = false
    /// Folders that could not be read; their contents are not in the list.
    private(set) var unreadable: [URL] = []
    private(set) var scannedCount = 0
    private(set) var currentDirectory: URL?
    private(set) var isStopping = false
    private(set) var trashProgress: RemovalProgressState?
    /// Set when "Show in Finder" hit an item that no longer exists.
    var missingItem: URL?
    let paths: SiftPaths

    private let scanner: any LargeFileScanning
    private let remover: any FindingRemoving
    private let lastUsed: any LastUsedLookup
    private let revealer: any FileRevealing
    private var scanTask: Task<Void, Never>?
    private var trashTask: Task<RemovalReport, Never>?

    init(
        scanner: any LargeFileScanning, remover: any FindingRemoving, lastUsed: any LastUsedLookup,
        revealer: any FileRevealing = LiveFileRevealer(), paths: SiftPaths = .live
    ) {
        self.scanner = scanner
        self.remover = remover
        self.lastUsed = lastUsed
        self.revealer = revealer
        self.paths = paths
    }

    static func live(paths: SiftPaths = .live) -> LargeFilesModel {
        LargeFilesModel(
            scanner: LargeFileScanner(paths: paths, minimumSize: thresholds[0]),
            remover: Remover(roots: .largeFiles(paths)), lastUsed: SpotlightLastUsedLookup(), paths: paths)
    }

    // MARK: scan

    var hasScanned: Bool { phase != .idle }

    func startScan() {
        guard phase == .idle || phase == .ready else { return }
        scanTask = Task { await scan() }
    }

    func stop() {
        scanTask?.cancel()
        stopTrash()
    }

    func waitForScan() async {
        await scanTask?.value
    }

    func scan() async {
        guard phase == .idle || phase == .ready else { return }
        phase = .scanning
        rows = []
        checked = []
        unreadable = []
        scannedCount = 0
        currentDirectory = nil
        scanStopped = false
        var completed = false
        let lastUsed = lastUsed
        for await event in scanner.scan() {
            switch event {
            case .found(let file):
                // Spotlight lookups block; keep them off the main actor
                let opened = await Task.detached { lastUsed.lastUsed(file.url) }.value
                rows.append(Row(file: file, lastOpened: opened))
            case .progress(let scanned, let directory):
                scannedCount = scanned
                currentDirectory = directory
            case .unreadable(let url):
                unreadable.append(url)
            case .finished:
                completed = true
            }
        }
        scanStopped = !completed
        currentDirectory = nil
        phase = .ready
    }

    // MARK: list

    /// Rows at or above the threshold, in the current sort order.
    var visibleRows: [Row] {
        let shown = rows.filter { $0.file.size >= threshold }
        switch sort {
        case .size:
            return shown.sorted { $0.file.size != $1.file.size ? $0.file.size > $1.file.size : name($0) < name($1) }
        case .name:
            return shown.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        case .date:
            // oldest first: the likeliest candidates for cleanup
            return shown.sorted { ($0.shownDate.date ?? .distantPast) < ($1.shownDate.date ?? .distantPast) }
        }
    }

    private func name(_ row: Row) -> String { row.file.url.lastPathComponent }

    var visibleTotal: Int64 { visibleRows.reduce(0) { $0 + $1.file.size } }

    // MARK: selection

    func isChecked(_ row: Row) -> Bool { checked.contains(row.id) }

    func setChecked(_ row: Row, _ on: Bool) {
        guard phase == .ready else { return }
        if on { checked.insert(row.id) } else { checked.remove(row.id) }
    }

    /// Checked rows that are visible; files hidden by the threshold are never trashed.
    var selectedRows: [Row] { visibleRows.filter { checked.contains($0.id) } }

    var selectedTotal: Int64 { selectedRows.reduce(0) { $0 + $1.file.size } }

    // MARK: trash

    func trash() async {
        guard phase == .ready else { return }
        let items = selectedRows.map(\.file.finding)
        guard !items.isEmpty else { return }
        phase = .trashing
        isStopping = false
        trashProgress = nil
        let remover = remover
        let task = Task.detached {
            await remover.remove(items, policy: .trash) { state in
                await MainActor.run { self.trashProgress = state }
            }
        }
        trashTask = task
        let report = await task.value
        trashTask = nil
        isStopping = false
        trashProgress = nil
        let gone = Set(report.removed.map(\.url.path))
        rows.removeAll { gone.contains($0.id) }
        checked.subtract(gone)
        phase = .report(report)
    }

    func stopTrash() {
        guard phase == .trashing else { return }
        isStopping = true
        trashTask?.cancel()
    }

    func closeReport() {
        guard case .report = phase else { return }
        phase = .ready
    }

    func reveal(_ url: URL) {
        if !revealer.reveal(url) { missingItem = url }
    }
}
