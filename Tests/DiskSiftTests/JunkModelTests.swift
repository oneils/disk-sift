import Foundation
import SiftCore
import Testing
import os

@testable import DiskSift

private struct FakeCategory: JunkCategory {
    var id: String
    var title: String
    var policy = RemovalPolicy.delete
    var expandable = true
    var removalScope = JunkRemovalScope.library
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

/// Hangs on the first scan (until stopped), then finishes with `events`.
private final class HangOnceScanner: JunkScanning {
    let events: [JunkProgress]
    let calls = OSAllocatedUnfairLock(initialState: 0)
    init(events: [JunkProgress]) { self.events = events }
    func scan() -> AsyncStream<JunkProgress> {
        let first = calls.withLock { count in
            count += 1
            return count == 1
        }
        let events = events
        return AsyncStream { continuation in
            if first {
                continuation.yield(.categoryStarted(id: "a"))
            } else {
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

private final class FakeRemover: FindingRemoving {
    let received = OSAllocatedUnfairLock<[[Finding]]>(initialState: [])
    let policies = OSAllocatedUnfairLock<[RemovalPolicy]>(initialState: [])
    let skipPath: String?
    let pauseOnFirst: Bool
    init(skipPath: String? = nil, pauseOnFirst: Bool = false) {
        self.skipPath = skipPath
        self.pauseOnFirst = pauseOnFirst
    }

    func remove(
        _ findings: [Finding],
        policy: RemovalPolicy,
        onProgress: (@Sendable (RemovalProgressState) async -> Void)? = nil
    ) async -> RemovalReport {
        received.withLock { $0.append(findings) }
        policies.withLock { $0.append(policy) }
        var report = RemovalReport()
        var processedBytes: Int64 = 0
        for (index, finding) in findings.enumerated() {
            if Task.isCancelled {
                report.stopped = true
                report.unprocessed = Array(findings[index...])
                break
            }
            await onProgress?(
                RemovalProgressState(
                    current: finding, completed: index, total: findings.count, processedBytes: processedBytes))
            if pauseOnFirst && index == 0 {
                while !Task.isCancelled { await Task.yield() }
            }
            if finding.url.path == skipPath {
                report.skipped.append(SkippedItem(url: finding.url, reason: .inUse))
            } else {
                report.removed.append(RemovedItem(url: finding.url, size: finding.size))
                processedBytes += finding.size ?? 0
            }
        }
        if Task.isCancelled && !report.stopped {
            report.stopped = true
        }
        return report
    }

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

/// Reveals only `existing` paths and records what was asked.
final class FakeRevealer: FileRevealing {
    let existing: Set<String>
    let revealed = OSAllocatedUnfairLock<[String]>(initialState: [])
    init(existing: Set<String> = []) { self.existing = existing }
    func reveal(_ url: URL) -> Bool {
        guard existing.contains(url.path) else { return false }
        revealed.withLock { $0.append(url.path) }
        return true
    }
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
        scanner: FakeScanner? = nil, remover: FakeRemover = FakeRemover(), lister: FakeLister? = nil,
        revealer: FakeRevealer = FakeRevealer()
    ) -> JunkModel {
        JunkModel(
            scanner: scanner ?? FakeScanner(events: events), remover: remover,
            categories: [FakeCategory(id: "a", title: "A"), FakeCategory(id: "b", title: "B")],
            runningApps: NoApps(), lister: lister ?? FakeLister([:]), revealer: revealer)
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
        // unfinished categories are marked incomplete, never shown as verified empty
        #expect(m.rows.map(\.state) == [.stopped, .stopped])
        #expect(m.scanStopped)
        #expect(!m.foundNothing)
    }

    @Test func beforeFirstScanNothingIsKnown() {
        let m = model()
        #expect(!m.hasScanned)
        #expect(m.rows.allSatisfy { $0.state == .pending })
        #expect(m.foundTotal == 0)
        #expect(!m.foundNothing)
        #expect(!m.scanStopped)
    }

    @Test func completeEmptyScanFoundNothing() async {
        let m = model(scanner: FakeScanner(events: [.categoryStarted(id: "a"), .categoryFinished(id: "a")]))
        await m.scan()
        #expect(m.hasScanned)
        #expect(m.foundNothing)
        #expect(!m.scanStopped)
        // "b" never reported: a finished stream still counts as complete, so it is not marked stopped
        #expect(m.rows[0].state == .done)
    }

    @Test func rescanClearsStoppedState() async {
        let m = JunkModel(
            scanner: HangOnceScanner(events: events), remover: FakeRemover(),
            categories: [FakeCategory(id: "a", title: "A"), FakeCategory(id: "b", title: "B")],
            runningApps: NoApps(), lister: FakeLister([:]), revealer: FakeRevealer())
        m.startScan()
        for _ in 0..<50 where m.rows[0].state != .scanning { await Task.yield() }
        m.stop()
        await m.waitForScan()
        #expect(m.scanStopped)
        await m.scan()
        #expect(!m.scanStopped)
        #expect(m.rows.allSatisfy { $0.state == .done })
    }

    @Test func foundTotalsAndSortKeepSelection() async {
        let m = model()
        await m.scan()
        #expect(m.foundTotal == 1167)
        #expect(m.foundCount == 5)
        let before = m.selectedFindings.map(\.id)
        m.sort = .name
        #expect(m.sortedFindings(m.rows[0]).map(\.url.lastPathComponent) == ["big", "keepme", "rootonly", "small"])
        #expect(m.selectedFindings.map(\.id) == before)
        m.sort = .size
        #expect(m.sortedFindings(m.rows[0]).map(\.url.lastPathComponent) == ["big", "keepme", "small", "rootonly"])
    }

    @Test func sortedChildrenFollowSort() async {
        let m = model(lister: lister)
        await m.scan()
        await m.expand(node(m, "/c/keepme"))
        m.sort = .name
        #expect(m.sortedChildren(of: "/c/keepme").map(\.url.lastPathComponent) == ["k1", "k2"])
        m.setChecked(id: "/c/keepme/k2", true)
        m.sort = .size
        #expect(m.state(of: "/c/keepme/k2") == .on)
        #expect(m.state(of: "/c/keepme") == .mixed)
    }

    @Test func categoryTriState() async {
        let m = model(lister: lister)
        await m.scan()
        #expect(m.categoryState(m.rows[0]) == .mixed)  // keepme unchecked
        #expect(m.categoryState(m.rows[1]) == .on)
        m.setCategoryChecked(m.rows[0], false)
        #expect(m.categoryState(m.rows[0]) == .off)
        await m.expand(node(m, "/c/big"))
        m.setChecked(id: "/c/big/g2", true)
        #expect(m.categoryState(m.rows[0]) == .mixed)  // only part of a finding
        #expect(m.hasSelectable(m.rows[0]))
    }

    @Test func revealMissingItemIsReported() {
        let revealer = FakeRevealer(existing: ["/c/big"])
        let m = model(revealer: revealer)
        m.reveal(URL(fileURLWithPath: "/c/big"))
        #expect(m.missingItem == nil)
        #expect(revealer.revealed.withLock { $0 } == ["/c/big"])
        m.reveal(URL(fileURLWithPath: "/c/gone"))
        #expect(m.missingItem?.path == "/c/gone")
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
        m.requestRemove()
        #expect(m.confirming)
        await m.remove()
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
        m.requestRemove()
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
        await m.remove()
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
        await m.remove()
        let sent = remover.received.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent[0].map(\.id) == ["/c/big/g1/x"])
        // parent stays, shrunk by what was removed
        let big = m.rows[0].findings.first { $0.id == "/c/big" }
        #expect(big?.size == 65)
        #expect(m.children(of: "/c/big/g1").map(\.id) == ["/c/big/g1/y"])
        #expect(m.children(of: "/c/big").first { $0.id == "/c/big/g1" }?.size == 25)
    }

    @Test(.timeLimit(.minutes(1))) func deleteStopCancelsAndLeavesRemaining() async {
        let remover = FakeRemover(pauseOnFirst: true)
        let m = model(remover: remover)
        await m.scan()
        let task = Task { await m.remove() }
        while m.removalProgress == nil { await Task.yield() }
        #expect(m.phase == .removing)
        #expect(m.removalProgress?.completed == 0)
        #expect(!m.isStopping)
        m.startScan()
        await m.remove()
        #expect(remover.received.withLock { $0.count } == 1)
        #expect(m.phase == .removing)
        m.stopRemove()
        #expect(m.isStopping)
        await task.value
        #expect(!m.isStopping)
        guard case .report(let report) = m.phase else {
            Issue.record("expected report after stop")
            return
        }
        #expect(report.stopped)
        #expect(!report.unprocessed.isEmpty)
        #expect(m.removalProgress == nil)
    }

    @Test func unreadableCategoryShowsNoAccessEvenIfFinishedFollows() async {
        let m = model(
            scanner: FakeScanner(events: [
                .categoryStarted(id: "a"), .categoryUnreadable(id: "a"), .categoryFinished(id: "a"),
                .categoryStarted(id: "b"), .categoryFinished(id: "b"),
            ]))
        await m.scan()
        #expect(m.rows[0].state == .noAccess)
        #expect(m.rows[1].state == .done)
        #expect(!m.scanStopped)
    }

    @Test func nonExpandableCategoryAndDisplayName() async {
        let named = Finding(
            url: URL(fileURLWithPath: "/b/00008030-ABC"), size: 5, confidence: .high, sources: [.junk(categoryID: "a")],
            displayName: "iPhone — 12 Oct 2026")
        let m = JunkModel(
            scanner: FakeScanner(events: [.findingSized(categoryID: "a", finding: named), .categoryFinished(id: "a")]),
            remover: FakeRemover(),
            categories: [FakeCategory(id: "a", title: "A", expandable: false), FakeCategory(id: "b", title: "B")],
            runningApps: NoApps(), lister: FakeLister([:]), revealer: FakeRevealer())
        await m.scan()
        let node = m.node(for: m.rows[0].findings[0], categoryID: "a")
        #expect(node.title == "iPhone — 12 Oct 2026")
        #expect(!m.canExpand(node))
        var other = node
        other.categoryID = "b"
        #expect(m.canExpand(other))
    }

    // MARK: mixed policies

    func item(_ path: String, _ category: String, _ size: Int64) -> Finding {
        Finding(url: URL(fileURLWithPath: path), size: size, confidence: .high, sources: [.junk(categoryID: category)])
    }

    fileprivate func mixedModel(
        library: FakeRemover, largeFiles: FakeRemover, snapshots: [LocalSnapshot] = [],
        snapshotReads: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0)
    ) -> JunkModel {
        let events: [JunkProgress] = [
            .findingSized(categoryID: "del", finding: item("/c/cache", "del", 10)),
            .findingSized(categoryID: "bak", finding: item("/b/backup", "bak", 1000)),
            .findingSized(categoryID: "ins", finding: item("/h/Downloads/App.dmg", "ins", 100)),
            .categoryFinished(id: "del"), .categoryFinished(id: "bak"), .categoryFinished(id: "ins"),
        ]
        return JunkModel(
            scanner: FakeScanner(events: events), remover: library, largeFilesRemover: largeFiles,
            categories: [
                FakeCategory(id: "del", title: "Del"),
                FakeCategory(id: "bak", title: "Bak", policy: .trash),
                FakeCategory(id: "ins", title: "Ins", policy: .trash, removalScope: .largeFiles),
            ],
            runningApps: NoApps(), lister: FakeLister([:]), revealer: FakeRevealer(),
            snapshots: {
                snapshotReads.withLock { $0 += 1 }
                return snapshots
            })
    }

    @Test func snapshotsAreReadAfterScanAndAfterDeletingPermanently() async {
        let snapshot = LocalSnapshot(name: "com.apple.TimeMachine.2026-11-21-180637.local", date: nil)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let m = mixedModel(
            library: FakeRemover(), largeFiles: FakeRemover(), snapshots: [snapshot], snapshotReads: reads)
        await m.scan()
        #expect(m.snapshots == [snapshot])
        #expect(reads.withLock { $0 } == 1)
        await m.remove()
        #expect(m.snapshots == [snapshot])
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func snapshotsAreNotReReadWhenEverythingWentToTheTrash() async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let m = mixedModel(
            library: FakeRemover(), largeFiles: FakeRemover(),
            snapshots: [LocalSnapshot(name: "s", date: nil)], snapshotReads: reads)
        await m.scan()
        m.setCategoryChecked(m.rows.first { $0.id == "del" }!, false)
        await m.remove()
        #expect(m.lastRemoved[.trash]?.count == 2)
        // read once by the scan, not again by a removal that only trashed
        #expect(reads.withLock { $0 } == 1)
    }

    @Test func batchesRouteByScopeAndPolicy() async {
        let library = FakeRemover()
        let large = FakeRemover()
        let m = mixedModel(library: library, largeFiles: large)
        await m.scan()
        #expect(m.selectedDeleteTotal == 10)
        #expect(m.selectedTrashTotal == 1100)
        await m.remove()
        #expect(library.received.withLock { $0.map { $0.map(\.id) } } == [["/c/cache"], ["/b/backup"]])
        #expect(library.policies.withLock { $0 } == [.delete, .trash])
        // installers never reach the library remover and never get .delete
        #expect(large.received.withLock { $0.map { $0.map(\.id) } } == [["/h/Downloads/App.dmg"]])
        #expect(large.policies.withLock { $0 } == [.trash])
        guard case .report(let report) = m.phase else {
            Issue.record("expected report")
            return
        }
        #expect(report.removed.count == 3)
        #expect(!report.stopped)
        #expect(m.lastRemoved[.delete]?.map(\.url.path) == ["/c/cache"])
        #expect(Set(m.lastRemoved[.trash]?.map(\.url.path) ?? []) == ["/b/backup", "/h/Downloads/App.dmg"])
    }

    @Test func childrenOfAFindingKeepTheirCategoryRoute() {
        let m = mixedModel(library: FakeRemover(), largeFiles: FakeRemover())
        let child = item("/b/backup/sub", "bak", 5)
        let batches = m.batches([child])
        #expect(batches.count == 1)
        #expect(batches[0].policy == .trash && batches[0].scope == .library)
        #expect(m.batches([item("/x", "unknown", 1)]).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func stopInFirstBatchLeavesLaterBatchesUnprocessed() async {
        let library = FakeRemover(pauseOnFirst: true)
        let large = FakeRemover()
        let m = mixedModel(library: library, largeFiles: large)
        await m.scan()
        let task = Task { await m.remove() }
        while m.removalProgress == nil { await Task.yield() }
        #expect(m.removalProgress?.total == 3)
        m.stopRemove()
        await task.value
        guard case .report(let report) = m.phase else {
            Issue.record("expected report")
            return
        }
        #expect(report.stopped)
        #expect(Set(report.unprocessed.map(\.id)).isSuperset(of: ["/b/backup", "/h/Downloads/App.dmg"]))
        #expect(large.received.withLock { $0 }.isEmpty)
    }
}
