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

private final class FakeLister: ChildListing {
    let tree: [String: [DirectoryChild]]
    let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
    init(_ tree: [String: [(String, Int64, DirectoryChild.Kind)]]) {
        self.tree = tree.mapValues { items in
            items.map { DirectoryChild(url: URL(fileURLWithPath: $0.0), kind: $0.2, size: $0.1) }
        }
    }
    func children(of url: URL) async throws -> [DirectoryChild] {
        calls.withLock { $0.append(url.path) }
        return tree[url.path] ?? []
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
        scanner: FakeScanner? = nil, remover: FakeRemover = FakeRemover(), lister: FakeLister? = nil
    ) -> JunkModel {
        JunkModel(
            scanner: scanner ?? FakeScanner(events: events), remover: remover,
            categories: [FakeCategory(id: "a", title: "A"), FakeCategory(id: "b", title: "B")],
            runningApps: NoApps(), lister: lister ?? FakeLister([:]))
    }

    fileprivate var lister: FakeLister {
        FakeLister([
            "/c/big": [("/c/big/g1", 60, .directory), ("/c/big/g2", 40, .file)],
            "/c/big/g1": [("/c/big/g1/x", 35, .file), ("/c/big/g1/y", 25, .file)],
            "/c/keepme": [("/c/keepme/k1", 30, .file), ("/c/keepme/k2", 20, .file)],
        ])
    }

    fileprivate func node(_ m: JunkModel, _ path: String) -> JunkModel.Node {
        let f = m.rows.flatMap(\.findings).first { $0.id == path }!
        return m.node(for: f, categoryID: "a")
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

    @Test func expandLoadsChildrenLazilyLargestFirst() async {
        let l = lister
        let m = model(lister: l)
        await m.scan()
        #expect(l.calls.withLock { $0 }.isEmpty)
        let big = node(m, "/c/big")
        await m.expand(big)
        #expect(l.calls.withLock { $0 } == ["/c/big"])
        #expect(m.children(of: "/c/big").map(\.url.lastPathComponent) == ["g1", "g2"])
        #expect(m.isExpanded("/c/big") && !m.isLoading("/c/big"))
        await m.expand(big)
        #expect(l.calls.withLock { $0 }.count == 1)
        // depth limit: grandchildren are not expandable
        let g1 = m.children(of: "/c/big")[0]
        #expect(m.canExpand(g1))
        await m.expand(g1)
        #expect(!m.canExpand(m.children(of: "/c/big/g1")[0]))
        #expect(!m.canExpand(g1, requiresRoot: true))
    }

    @Test func inheritedDefaultFollowsParent() async {
        let m = model(lister: lister)
        await m.scan()
        await m.expand(node(m, "/c/big"))  // checked by default
        await m.expand(node(m, "/c/keepme"))  // unchecked by default
        #expect(m.children(of: "/c/big").allSatisfy { m.state(of: $0.id) == .on })
        #expect(m.children(of: "/c/keepme").allSatisfy { m.state(of: $0.id) == .off })
    }

    @Test func triStatePropagation() async {
        let m = model(lister: lister)
        await m.scan()
        await m.expand(node(m, "/c/big"))
        await m.expand(m.children(of: "/c/big")[0])
        m.setChecked(id: "/c/big/g1/x", false)
        #expect(m.state(of: "/c/big/g1") == .mixed)
        #expect(m.state(of: "/c/big") == .mixed)
        m.setChecked(id: "/c/big/g1/y", false)
        #expect(m.state(of: "/c/big/g1") == .off)
        #expect(m.state(of: "/c/big") == .mixed)  // g2 still checked
        m.setChecked(id: "/c/big/g2", false)
        #expect(m.state(of: "/c/big") == .off)
        m.setChecked(id: "/c/big", true)
        #expect(m.state(of: "/c/big/g1/x") == .on && m.state(of: "/c/big/g2") == .on)
        m.setChecked(id: "/c/big/g1/x", true)
        m.setChecked(id: "/c/big/g1/y", true)
        #expect(m.state(of: "/c/big") == .on)
        m.setChecked(id: "/c/big", false)
        #expect(m.state(of: "/c/big/g1/y") == .off)
    }

    @Test func totalsNeverDoubleCount() async {
        let m = model(lister: lister)
        await m.scan()
        #expect(m.selectedTotal == 1110)
        await m.expand(node(m, "/c/big"))
        #expect(m.selectedTotal == 1110)
        m.setChecked(id: "/c/big/g2", false)  // big is now mixed: only g1 (60) counts instead of 100
        #expect(m.selectedTotal == 1070)
        #expect(m.selectedTotal(in: m.rows[0]) == 70)
        #expect(Set(m.selectedFindings.map(\.id)) == ["/c/big/g1", "/c/small", "/d/x"])
    }

    @Test func deleteWholeParentPassesOnlyParent() async {
        let remover = FakeRemover()
        let m = model(remover: remover, lister: lister)
        await m.scan()
        await m.expand(node(m, "/c/big"))
        m.setCategoryChecked(m.rows[1], false)
        m.setChecked(id: "/c/small", false)
        await m.delete()
        let sent = remover.received.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent[0].map(\.id) == ["/c/big"])
        #expect(!m.rows[0].findings.contains { $0.id == "/c/big" })
        #expect(m.children(of: "/c/big").isEmpty)
    }

    @Test func deleteMixedParentPassesOnlyCheckedChildren() async {
        let remover = FakeRemover()
        let m = model(remover: remover, lister: lister)
        await m.scan()
        await m.expand(node(m, "/c/big"))
        await m.expand(m.children(of: "/c/big")[0])
        m.setCategoryChecked(m.rows[1], false)
        m.setChecked(id: "/c/small", false)
        m.setChecked(id: "/c/big/g2", false)
        m.setChecked(id: "/c/big/g1/y", false)
        await m.delete()
        let sent = remover.received.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent[0].map(\.id) == ["/c/big/g1/x"])
        // parent stays, shrunk by what was removed
        let big = m.rows[0].findings.first { $0.id == "/c/big" }
        #expect(big?.size == 65)
        #expect(m.children(of: "/c/big/g1").map(\.id) == ["/c/big/g1/y"])
        #expect(m.children(of: "/c/big").first { $0.id == "/c/big/g1" }?.size == 25)
    }
}
