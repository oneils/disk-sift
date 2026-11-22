import Foundation
import SiftCore
import Testing
import os

@testable import DiskSift

private struct FakeOrphanScanner: OrphanScanning {
    var groups: [OrphanGroup]
    /// Wait until cancelled, then throw.
    var hang = false
    func scan() async throws -> [OrphanGroup] {
        if hang {
            while !Task.isCancelled { await Task.yield() }
            throw CancellationError()
        }
        return groups
    }
}

private final class FakeOrphanRemover: OrphanRemoving {
    let received = OSAllocatedUnfairLock<[[String]]>(initialState: [])
    let skip: Set<String>
    let pauseOnFirst: Bool
    init(skip: Set<String> = [], pauseOnFirst: Bool = false) {
        self.skip = skip
        self.pauseOnFirst = pauseOnFirst
    }
    func remove(
        _ findings: [Finding], onProgress: (@Sendable (RemovalProgressState) async -> Void)?
    ) async -> RemovalReport {
        received.withLock { $0.append(findings.map(\.id)) }
        var report = RemovalReport()
        for (index, finding) in findings.enumerated() {
            if Task.isCancelled {
                report.stopped = true
                report.unprocessed = Array(findings[index...])
                break
            }
            await onProgress?(
                RemovalProgressState(current: finding, completed: index, total: findings.count, processedBytes: 0))
            if pauseOnFirst && index == 0 { while !Task.isCancelled { await Task.yield() } }
            if skip.contains(finding.id) {
                report.skipped.append(SkippedItem(url: finding.url, reason: .inUse))
            } else {
                report.removed.append(RemovedItem(url: finding.url, size: finding.size))
            }
        }
        return report
    }
}

@MainActor
@Suite private struct OrphansModelTests {
    func finding(_ path: String, _ group: String, _ size: Int64, root: Bool = false) -> Finding {
        Finding(
            url: URL(fileURLWithPath: path), size: size, confidence: .medium, sources: [.orphan(groupID: group)],
            requiresRoot: root, evidence: [.appNotInstalled])
    }

    var groups: [OrphanGroup] {
        [
            OrphanGroup(
                id: "com.big.app",
                findings: [
                    finding("/l/Caches/com.big.app", "com.big.app", 500),
                    finding("/l/Preferences/com.big.app.plist", "com.big.app", 4),
                    finding("/L/Caches/com.big.app", "com.big.app", 10, root: true),
                ]),
            OrphanGroup(id: "com.alpha.tool", findings: [finding("/l/Caches/com.alpha.tool", "com.alpha.tool", 20)]),
        ]
    }

    func model(
        groups: [OrphanGroup]? = nil, hang: Bool = false, remover: FakeOrphanRemover = FakeOrphanRemover(),
        revealer: FakeRevealer = FakeRevealer()
    ) -> OrphansModel {
        OrphansModel(
            scanner: FakeOrphanScanner(groups: groups ?? self.groups, hang: hang), remover: remover,
            revealer: revealer, paths: SiftPaths(root: URL(fileURLWithPath: "/r")))
    }

    @Test func nothingSelectedAfterScan() async {
        let m = model()
        await m.scan()
        #expect(m.phase == .results)
        #expect(m.selectedFindings.isEmpty)
        #expect(m.foundCount == 4)
        #expect(m.foundTotal == 534)
    }

    @Test func rootOnlyFindingIsNotSelectableAndIgnoredByGroupState() async {
        let m = model()
        await m.scan()
        let big = m.groups[0]
        let root = big.findings[2]
        m.setChecked(root, true)
        #expect(!m.isChecked(root))
        m.setChecked(big.findings[0], true)
        #expect(m.groupState(big) == .mixed)
        m.setChecked(big.findings[1], true)
        #expect(m.groupState(big) == .on)  // the root-only item doesn't keep it mixed
        m.setGroup(big, false)
        #expect(m.groupState(big) == .off)
        m.setGroup(big, true)
        #expect(m.selectedFindings.map(\.id) == ["/l/Caches/com.big.app", "/l/Preferences/com.big.app.plist"])
        #expect(m.selectedTotal == 504)
    }

    @Test func sortKeepsSelection() async {
        let m = model()
        await m.scan()
        m.setChecked(m.groups[1].findings[0], true)
        #expect(m.sortedGroups.map(\.id) == ["com.big.app", "com.alpha.tool"])
        m.sort = .name
        #expect(m.sortedGroups.map(\.id) == ["com.alpha.tool", "com.big.app"])
        #expect(m.selectedFindings.map(\.id) == ["/l/Caches/com.alpha.tool"])
    }

    @Test func onlySelectedFindingsReachTheRemoverAndReportPrunes() async {
        let remover = FakeOrphanRemover(skip: ["/l/Preferences/com.big.app.plist"])
        let m = model(remover: remover)
        await m.scan()
        m.setGroup(m.groups[0], true)
        m.setGroup(m.groups[1], true)
        await m.remove()
        #expect(
            remover.received.withLock { $0 } == [
                ["/l/Caches/com.big.app", "/l/Preferences/com.big.app.plist", "/l/Caches/com.alpha.tool"]
            ])
        guard case .report(let report) = m.phase else {
            Issue.record("expected report")
            return
        }
        #expect(report.removed.count == 2)
        // alpha's only finding was removed: the group is gone; big keeps the skipped and root-only items
        #expect(m.groups.map(\.id) == ["com.big.app"])
        #expect(m.groups[0].findings.map(\.id) == ["/l/Preferences/com.big.app.plist", "/L/Caches/com.big.app"])
        m.closeReport()
        #expect(m.phase == .results)
    }

    @Test func stopDuringScanReturnsToStart() async {
        let m = model(hang: true)
        m.startScan()
        for _ in 0..<100 where m.phase != .scanning { await Task.yield() }
        #expect(m.phase == .scanning)
        m.stop()
        await m.waitForScan()
        #expect(m.phase == .idle)
        #expect(m.groups.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func stopAfterCurrentItem() async {
        let m = model(remover: FakeOrphanRemover(pauseOnFirst: true))
        await m.scan()
        m.setGroup(m.groups[0], true)
        let task = Task { await m.remove() }
        while m.removalProgress == nil { await Task.yield() }
        #expect(m.phase == .removing)
        m.stopRemove()
        #expect(m.isStopping)
        await task.value
        guard case .report(let report) = m.phase else {
            Issue.record("expected report")
            return
        }
        #expect(report.stopped)
        #expect(!m.isStopping)
    }

    @Test func closeReturnsToStartAndRevealReportsMissing() async {
        let m = model(revealer: FakeRevealer(existing: ["/l/Caches/com.big.app"]))
        await m.scan()
        m.reveal(URL(fileURLWithPath: "/l/Caches/com.big.app"))
        #expect(m.missingItem == nil)
        m.reveal(URL(fileURLWithPath: "/l/gone"))
        #expect(m.missingItem?.path == "/l/gone")
        m.close()
        #expect(m.phase == .idle)
        #expect(m.groups.isEmpty)
    }

    /// The kept totals always match what the raw selection says.
    private func expectConsistent(_ m: OrphansModel, sourceLocation: SourceLocation = #_sourceLocation) {
        let selected = m.groups.flatMap(\.findings).filter { m.isChecked($0) }
        #expect(selected.allSatisfy { !$0.requiresRoot }, sourceLocation: sourceLocation)
        #expect(m.selectedTotal == selected.reduce(0) { $0 + ($1.size ?? 0) }, sourceLocation: sourceLocation)
        #expect(m.hasSelection == !selected.isEmpty, sourceLocation: sourceLocation)
        for section in m.sortedGroups {
            let on = section.selectableIDs.filter { m.isChecked(id: $0) }.count
            let expected: JunkModel.CheckState =
                on == 0 ? .off : (on == section.selectableIDs.count ? .on : .mixed)
            #expect(m.groupState(section) == expected, sourceLocation: sourceLocation)
            #expect(m.groupState(section.group) == expected, sourceLocation: sourceLocation)
        }
    }

    @Test func keptTotalsFollowEverySelectionChange() async {
        let remover = FakeOrphanRemover(skip: ["/l/Preferences/com.big.app.plist"])
        let m = model(remover: remover)
        await m.scan()
        expectConsistent(m)
        let big = m.groups[0]
        m.setChecked(big.findings[0], true)
        m.setChecked(big.findings[0], true)  // twice: counted once
        expectConsistent(m)
        m.setChecked(big.findings[2], true)  // root-only: ignored
        expectConsistent(m)
        m.setGroup(m.sortedGroups[1], true)
        expectConsistent(m)
        m.setGroup(big, true)
        expectConsistent(m)
        #expect(m.selectedTotal == 524)
        m.setChecked(big.findings[1], false)
        m.setChecked(big.findings[1], false)
        expectConsistent(m)
        m.setGroup(big, true)
        await m.remove()
        // removed items leave the selection; the skipped one stays selected
        expectConsistent(m)
        #expect(m.selectedTotal == 4)
        m.closeReport()
        await m.scan()
        expectConsistent(m)
        #expect(m.selectedTotal == 0)
        m.setGroup(m.groups[0], true)
        m.close()
        expectConsistent(m)
        #expect(!m.hasSelection)
    }

    @Test func rowsArePrecomputed() async {
        let paths = SiftPaths(root: URL(fileURLWithPath: "/r"))
        let caches = paths.library.appendingPathComponent("Caches/com.gone.app")
        let group = OrphanGroup(id: "com.gone.app", findings: [finding(caches.path, "com.gone.app", 9)])
        let m = OrphansModel(
            scanner: FakeOrphanScanner(groups: [group]), remover: FakeOrphanRemover(), revealer: FakeRevealer(),
            paths: paths)
        await m.scan()
        let row = m.sortedGroups[0].rows[0]
        #expect(row.id == caches.path)
        #expect(row.name == "com.gone.app")
        #expect(row.kindKey == LocationKind.caches.titleKey)
        #expect(row.parentPath == "~/Library/Caches")
        #expect(row.evidenceKeys == row.finding.evidenceKeys)
        #expect(m.sortedGroups[0].totalSize == 9)
        #expect(m.sortedGroups[0].selectableIDs == [caches.path])
    }

    @Test func storedSortFollowsRemovalAndSortChanges() async {
        let m = model()
        await m.scan()
        m.sort = .name
        m.setGroup(m.groups[1], true)
        await m.remove()
        #expect(m.sortedGroups.map(\.id) == ["com.big.app"])
        #expect(m.foundCount == 3)
        #expect(m.foundTotal == 514)
        m.sort = .size
        #expect(m.sortedGroups.map(\.id) == ["com.big.app"])
    }
}
