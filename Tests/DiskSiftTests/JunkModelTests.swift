import Foundation
import SiftCore
import Testing
import os

@testable import DiskSift

private struct FakeCategory: JunkCategory {
    var id: String
    var title: String
    var policy = RemovalPolicy.delete
    func scan(paths: SiftPaths) async throws -> [Finding] { [] }
    func checkedByDefault(_ finding: Finding, running: [RunningApp]) -> Bool {
        !finding.url.lastPathComponent.hasPrefix("keep")
    }
}

private struct FakeScanner: JunkScanning {
    var events: [JunkProgress]
    /// Keep the stream open after the events (until cancelled).
    var hang = false

    func scan() -> AsyncStream<JunkProgress> {
        let events = events
        let hang = hang
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            if !hang { continuation.finish() }
        }
    }
}

private final class FakeRemover: FindingRemoving {
    let received = OSAllocatedUnfairLock<[[Finding]]>(initialState: [])
    let skipPath: String?
    init(skipPath: String? = nil) { self.skipPath = skipPath }

    func remove(_ findings: [Finding], policy: RemovalPolicy) -> RemovalReport {
        received.withLock { $0.append(findings) }
        var report = RemovalReport()
        for finding in findings {
            if finding.url.path == skipPath {
                report.skipped.append(SkippedItem(url: finding.url, reason: .inUse))
            } else {
                report.removed.append(RemovedItem(url: finding.url, size: finding.size))
            }
        }
        return report
    }
}

private struct NoApps: RunningApps {
    func running() -> [RunningApp] { [] }
}

@MainActor
@Suite private struct JunkModelTests {
    func finding(_ path: String, _ size: Int64, root: Bool = false) -> Finding {
        Finding(
            url: URL(fileURLWithPath: path), size: size, confidence: .high,
            sources: [.junk(categoryID: "a")], requiresRoot: root)
    }

    var events: [JunkProgress] {
        [
            .categoryStarted(id: "a"), .categoryStarted(id: "b"),
            .findingSized(categoryID: "a", finding: finding("/c/small", 10)),
            .findingSized(categoryID: "a", finding: finding("/c/big", 100)),
            .findingSized(categoryID: "a", finding: finding("/c/keepme", 50)),
            .findingSized(categoryID: "a", finding: finding("/c/rootonly", 7, root: true)),
            .categoryFinished(id: "a"),
            .findingSized(categoryID: "b", finding: finding("/d/x", 1000)),
            .categoryFinished(id: "b"),
        ]
    }

    fileprivate func model(
        scanner: FakeScanner? = nil, remover: FakeRemover = FakeRemover()
    ) -> JunkModel {
        JunkModel(
            scanner: scanner ?? FakeScanner(events: events), remover: remover,
            categories: [FakeCategory(id: "a", title: "A"), FakeCategory(id: "b", title: "B")],
            runningApps: NoApps())
    }

    @Test func progressAggregation() async {
        let m = model()
        await m.scan()
        #expect(m.phase == .ready)
        #expect(m.finishedCount == 2)
        #expect(m.rows[0].findings.map(\.url.lastPathComponent) == ["big", "keepme", "small", "rootonly"])
        #expect(m.rows[0].total == 167)
        #expect(m.rows[1].total == 1000)
        #expect(m.rows.allSatisfy { $0.state == .done })
    }

    @Test func rowsShowScanningMidScan() async {
        let m = model(scanner: FakeScanner(events: [.categoryStarted(id: "a")], hang: true))
        m.startScan()
        await Task.yield()
        for _ in 0..<50 where m.rows[0].state != .scanning { await Task.yield() }
        #expect(m.phase == .scanning)
        #expect(m.rows[0].state == .scanning)
        m.stop()
        await m.waitForScan()
        #expect(m.phase == .ready)
        #expect(m.rows[0].state == .done)
    }

    @Test func cancelKeepsFindingsSoFar() async {
        let partial = Array(events.prefix(4))
        let m = model(scanner: FakeScanner(events: partial, hang: true))
        m.startScan()
        for _ in 0..<50 where m.rows[0].findings.count < 2 { await Task.yield() }
        m.stop()
        await m.waitForScan()
        #expect(m.phase == .ready)
        #expect(m.rows[0].findings.count == 2)
        #expect(m.selectedTotal == 110)
    }

    @Test func selectionTotals() async {
        let m = model()
        await m.scan()
        // defaults: everything except "keepme" and the root-only item
        #expect(m.selectedTotal == 1110)
        let a = m.rows[0]
        #expect(!m.isCategoryChecked(a))
        m.setCategoryChecked(a, true)
        #expect(m.isCategoryChecked(a))
        #expect(m.selectedTotal(in: m.rows[0]) == 160)
        #expect(m.selectedTotal == 1160)
        m.setCategoryChecked(m.rows[1], false)
        #expect(m.selectedTotal == 160)
        #expect(m.selectedFindings.allSatisfy { !$0.requiresRoot })
    }

    @Test func deleteReportWithSkippedItems() async {
        let remover = FakeRemover(skipPath: "/c/small")
        let m = model(remover: remover)
        await m.scan()
        m.requestDelete()
        #expect(m.confirming)
        await m.delete()
        #expect(!m.confirming)
        guard case .report(let report) = m.phase else {
            Issue.record("expected report")
            return
        }
        #expect(report.removed.count == 2)
        #expect(report.skipped == [SkippedItem(url: URL(fileURLWithPath: "/c/small"), reason: .inUse)])
        // removed items disappear from the list, skipped one stays
        #expect(m.rows[0].findings.map(\.url.lastPathComponent) == ["keepme", "small", "rootonly"])
        #expect(m.rows[1].findings.isEmpty)
        m.closeReport()
        #expect(m.phase == .ready)
    }

    @Test func deleteWithNothingSelectedDoesNothing() async {
        let m = model()
        await m.scan()
        for row in m.rows { m.setCategoryChecked(row, false) }
        m.requestDelete()
        #expect(!m.confirming)
    }
}
