import Foundation
import SiftCore
import Testing
import os

@testable import DiskSift

private struct FakeLargeScanner: LargeFileScanning {
    var events: [LargeFileProgress]
    /// Keep the stream open after the events (until cancelled).
    var hang = false

    func scan() -> AsyncStream<LargeFileProgress> {
        let events = events
        let hang = hang
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            if !hang { continuation.finish() }
        }
    }
}

private final class RecordingRemover: FindingRemoving {
    let calls = OSAllocatedUnfairLock<[([String], RemovalPolicy)]>(initialState: [])
    let skip: Set<String>
    let pauseOnFirst: Bool
    init(skip: Set<String> = [], pauseOnFirst: Bool = false) {
        self.skip = skip
        self.pauseOnFirst = pauseOnFirst
    }

    func remove(
        _ findings: [Finding], policy: RemovalPolicy,
        onProgress: (@Sendable (RemovalProgressState) async -> Void)?
    ) async -> RemovalReport {
        calls.withLock { $0.append((findings.map(\.id), policy)) }
        var report = RemovalReport()
        for (index, finding) in findings.enumerated() {
            if Task.isCancelled {
                report.stopped = true
                report.unprocessed = Array(findings[index...])
                break
            }
            await onProgress?(
                RemovalProgressState(current: finding, completed: index, total: findings.count, processedBytes: 0))
            if pauseOnFirst && index == 0 {
                while !Task.isCancelled { await Task.yield() }
            }
            if skip.contains(finding.id) {
                report.skipped.append(SkippedItem(url: finding.url, reason: .inUse))
            } else {
                report.removed.append(RemovedItem(url: finding.url, size: finding.size))
            }
        }
        return report
    }

    func remove(_ findings: [Finding], policy: RemovalPolicy) -> RemovalReport { RemovalReport() }
}

private struct DatesLookup: LastUsedLookup {
    var dates: [String: Date] = [:]
    func lastUsed(_ url: URL) -> Date? { dates[url.path] }
}

@MainActor
@Suite private struct LargeFilesModelTests {
    static let mb: Int64 = 1_000_000
    let old = Date(timeIntervalSince1970: 1_600_000_000)
    let recent = Date(timeIntervalSince1970: 1_700_000_000)

    func file(_ path: String, mb: Int64, modified: Date? = nil) -> LargeFile {
        LargeFile(url: URL(fileURLWithPath: path), size: mb * Self.mb, modified: modified)
    }

    var events: [LargeFileProgress] {
        [
            .progress(scanned: 500, directory: URL(fileURLWithPath: "/h/Movies")),
            .found(file("/h/Movies/a.mov", mb: 2000, modified: recent)),
            .found(file("/h/Downloads/b.iso", mb: 700, modified: old)),
            .found(file("/h/Downloads/c.zip", mb: 150, modified: recent)),
            .unreadable(URL(fileURLWithPath: "/h/Private")),
            .finished,
        ]
    }

    func model(
        events: [LargeFileProgress]? = nil, hang: Bool = false, remover: RecordingRemover = RecordingRemover(),
        dates: [String: Date] = [:], revealer: FakeRevealer = FakeRevealer()
    ) -> LargeFilesModel {
        LargeFilesModel(
            scanner: FakeLargeScanner(events: events ?? self.events, hang: hang), remover: remover,
            lastUsed: DatesLookup(dates: dates), revealer: revealer,
            paths: SiftPaths(root: URL(fileURLWithPath: "/r")))
    }

    @Test func startState() {
        let m = model()
        #expect(!m.hasScanned)
        #expect(m.threshold == LargeFilesModel.defaultThreshold)
        #expect(m.visibleRows.isEmpty)
    }

    @Test func scanCollectsAndFinishes() async {
        let m = model()
        await m.scan()
        #expect(m.phase == .ready)
        #expect(!m.scanStopped)
        #expect(m.rows.count == 3)
        #expect(m.unreadable.map(\.path) == ["/h/Private"])
        #expect(m.scannedCount == 500)
        #expect(m.currentDirectory == nil)
    }

    @Test func thresholdFiltersWithoutRescanAndHidesFromSelection() async {
        let m = model()
        await m.scan()
        #expect(m.visibleRows.map(\.file.url.lastPathComponent) == ["a.mov", "b.iso"])
        m.threshold = 100 * Self.mb
        #expect(m.visibleRows.count == 3)
        let c = m.visibleRows.first { $0.file.url.lastPathComponent == "c.zip" }!
        m.setChecked(c, true)
        #expect(m.selectedTotal == 150 * Self.mb)
        m.threshold = 1_000 * Self.mb
        #expect(m.visibleRows.map(\.file.url.lastPathComponent) == ["a.mov"])
        #expect(m.selectedRows.isEmpty)
        #expect(m.selectedTotal == 0)
    }

    @Test func nothingSelectedByDefaultAndSortKeepsSelection() async {
        let m = model()
        await m.scan()
        #expect(m.selectedRows.isEmpty)
        let b = m.visibleRows[1]
        m.setChecked(b, true)
        m.sort = .name
        #expect(m.visibleRows.map(\.file.url.lastPathComponent) == ["a.mov", "b.iso"])
        m.sort = .date
        #expect(m.visibleRows.map(\.file.url.lastPathComponent) == ["b.iso", "a.mov"])
        #expect(m.selectedRows.map(\.id) == [b.id])
    }

    @Test func openedDateFromLookupFallsBackToModified() async {
        let opened = Date(timeIntervalSince1970: 1_650_000_000)
        let m = model(dates: ["/h/Movies/a.mov": opened])
        await m.scan()
        let a = m.rows.first { $0.id == "/h/Movies/a.mov" }!
        #expect(a.shownDate.date == opened && a.shownDate.isOpened)
        let b = m.rows.first { $0.id == "/h/Downloads/b.iso" }!
        #expect(b.shownDate.date == old && !b.shownDate.isOpened)
    }

    @Test func stopDuringScanMarksIncomplete() async {
        let m = model(events: [.found(file("/h/a", mb: 600))], hang: true)
        m.startScan()
        for _ in 0..<100 where m.rows.isEmpty { await Task.yield() }
        m.stop()
        await m.waitForScan()
        #expect(m.phase == .ready)
        #expect(m.scanStopped)
        #expect(m.rows.count == 1)
    }

    @Test func trashSendsOnlySelectedVisibleFilesToTrash() async {
        let remover = RecordingRemover(skip: ["/h/Downloads/b.iso"])
        let m = model(remover: remover)
        await m.scan()
        m.threshold = 100 * Self.mb
        for row in m.visibleRows { m.setChecked(row, true) }
        m.threshold = 500 * Self.mb
        await m.trash()
        let calls = remover.calls.withLock { $0 }
        #expect(calls.count == 1)
        #expect(Set(calls[0].0) == ["/h/Movies/a.mov", "/h/Downloads/b.iso"])
        #expect(calls[0].1 == .trash)
        guard case .report(let report) = m.phase else {
            Issue.record("expected report")
            return
        }
        #expect(report.removed.map(\.url.path) == ["/h/Movies/a.mov"])
        // removed file leaves the list; skipped and hidden ones stay
        #expect(Set(m.rows.map(\.id)) == ["/h/Downloads/b.iso", "/h/Downloads/c.zip"])
        m.closeReport()
        #expect(m.phase == .ready)
    }

    @Test(.timeLimit(.minutes(1))) func stopAfterCurrentItem() async {
        let remover = RecordingRemover(pauseOnFirst: true)
        let m = model(remover: remover)
        await m.scan()
        for row in m.visibleRows { m.setChecked(row, true) }
        let task = Task { await m.trash() }
        while m.trashProgress == nil { await Task.yield() }
        #expect(m.phase == .trashing)
        m.stopTrash()
        #expect(m.isStopping)
        await task.value
        guard case .report(let report) = m.phase else {
            Issue.record("expected report")
            return
        }
        #expect(report.stopped)
        #expect(!m.isStopping)
    }

    @Test func revealMissingItem() {
        let m = model(revealer: FakeRevealer(existing: ["/h/a"]))
        m.reveal(URL(fileURLWithPath: "/h/a"))
        #expect(m.missingItem == nil)
        m.reveal(URL(fileURLWithPath: "/h/gone"))
        #expect(m.missingItem?.path == "/h/gone")
    }
}
