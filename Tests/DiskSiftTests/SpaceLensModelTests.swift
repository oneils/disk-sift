import Foundation
import SiftCore
import Testing
import os

@testable import DiskSift

private struct FakeSpaceScanner: SpaceScanning {
    let tree: SpaceTree?
    func scan(progress: (@Sendable (SpaceScanner.Progress) -> Void)?) async throws -> SpaceTree {
        progress?(SpaceScanner.Progress(items: 3, bytes: 10))
        guard let tree else { throw CancellationError() }
        return tree
    }
}

private final class RecordingRemover: FindingRemoving, @unchecked Sendable {
    let received = OSAllocatedUnfairLock<[[String]]>(initialState: [])
    let policies = OSAllocatedUnfairLock<[RemovalPolicy]>(initialState: [])
    var skip: Set<String> = []

    func remove(
        _ findings: [Finding], policy: RemovalPolicy, onProgress: (@Sendable (RemovalProgressState) async -> Void)?
    ) async -> RemovalReport {
        remove(findings, policy: policy)
    }

    func remove(_ findings: [Finding], policy: RemovalPolicy) -> RemovalReport {
        received.withLock { $0.append(findings.map(\.url.lastPathComponent)) }
        policies.withLock { $0.append(policy) }
        var report = RemovalReport()
        for f in findings {
            if skip.contains(f.url.lastPathComponent) {
                report.skipped.append(SkippedItem(url: f.url, reason: .inUse))
            } else {
                report.removed.append(RemovedItem(url: f.url, size: f.size))
            }
        }
        return report
    }
}

/// A real temp home, so `RemovalRoots.spaceLens` can judge real paths:
/// ~/Projects/app/{node_modules/, big.bin}, ~/Library/Caches/, ~/notes.txt
@MainActor
private final class Home {
    let root: URL
    let paths: SiftPaths
    let tree: SpaceTree

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("disksift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(
            fileURLWithPath: realpath(base.path, nil).map { p in
                defer { free(p) }
                return String(cString: p)
            }!)
        paths = SiftPaths(root: root)
        let fm = FileManager.default
        for dir in ["home/Projects/app/node_modules", "home/Library/Caches"] {
            try fm.createDirectory(at: paths.root(dir), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: paths.root("home/Projects/app/big.bin").path, contents: Data())
        fm.createFile(atPath: paths.root("home/notes.txt").path, contents: Data())
        tree = SpaceTree(
            root: paths.home,
            nodes: [
                SpaceNode(name: paths.home.path, parent: -1, kind: .directory, size: 1000, children: [1, 5, 7]),
                SpaceNode(name: "Projects", parent: 0, kind: .directory, size: 600, children: [2]),
                SpaceNode(name: "app", parent: 1, kind: .directory, size: 600, children: [3, 4]),
                SpaceNode(name: "node_modules", parent: 2, kind: .directory, size: 450),
                SpaceNode(name: "big.bin", parent: 2, kind: .file, size: 150),
                SpaceNode(name: "Library", parent: 0, kind: .directory, size: 380, children: [6]),
                SpaceNode(name: "Caches", parent: 5, kind: .directory, size: 380),
                SpaceNode(name: "", parent: 0, kind: .otherFiles(count: 1), size: 20),
            ])
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

extension SiftPaths {
    fileprivate func root(_ relative: String) -> URL {
        home.deletingLastPathComponent().appendingPathComponent(relative)
    }
}

@MainActor
@Suite struct SpaceLensModelTests {
    private func model(_ home: Home, remover: RecordingRemover = RecordingRemover(), tree: SpaceTree? = nil)
        async -> SpaceLensModel
    {
        let m = SpaceLensModel(
            scanner: FakeSpaceScanner(tree: tree ?? home.tree), remover: remover,
            roots: .spaceLens(home.paths), revealer: FakeRevealer(), paths: home.paths)
        await m.scan()
        return m
    }

    private func row(_ m: SpaceLensModel, _ name: String) -> SpaceLensModel.Row? {
        m.rows.first { $0.name == name }
    }

    @Test func scanShowsTheHomeFolderLargestFirst() async throws {
        let home = try Home()
        let m = await model(home)
        #expect(m.phase == .ready)
        #expect(m.current == 0)
        #expect(m.rows.map(\.id) == [1, 5, 7])
        #expect(m.breadcrumbs.map(\.name) == ["~"])
        #expect(m.currentSize == 1000)
    }

    @Test func libraryAndOtherFilesAreViewOnly() async throws {
        let home = try Home()
        let m = await model(home)
        #expect(row(m, "Projects")?.removable == true)
        #expect(row(m, "Library")?.removable == false)
        #expect(m.rows.last?.removable == false)  // smaller files
        m.open(5)
        #expect(row(m, "Caches")?.removable == false)
    }

    @Test func drillDownAndBack() async throws {
        let home = try Home()
        let m = await model(home)
        m.open(1)
        m.open(2)
        #expect(m.breadcrumbs.map(\.name) == ["~", "Projects", "app"])
        #expect(m.rows.map(\.name) == ["node_modules", "big.bin"])
        m.open(4)  // a file can't be opened
        #expect(m.current == 2)
        m.goUp()
        #expect(m.current == 1)
        m.open(0)
        #expect(m.current == 0)
    }

    @Test func selectingAFolderCoversWhatIsBelowIt() async throws {
        let home = try Home()
        let m = await model(home)
        m.open(1)
        m.open(2)
        m.setChecked(try #require(row(m, "node_modules")), true)
        #expect(m.selectedTotal == 450)
        m.goUp()
        let app = try #require(row(m, "app"))
        m.setChecked(app, true)
        // the folder replaces its selected child
        #expect(m.checked == [2])
        #expect(m.selectedTotal == 600)
        m.open(2)
        let modules = try #require(row(m, "node_modules"))
        #expect(m.isCoveredBySelection(modules))
        m.setChecked(modules, true)
        #expect(m.checked == [2])
    }

    @Test func viewOnlyRowsCannotBeSelected() async throws {
        let home = try Home()
        let m = await model(home)
        m.setChecked(try #require(row(m, "Library")), true)
        #expect(!m.hasSelection)
    }

    @Test func removalTrashesAndShrinksTheTree() async throws {
        let home = try Home()
        let remover = RecordingRemover()
        let m = await model(home, remover: remover)
        m.open(1)
        m.open(2)
        m.setChecked(try #require(row(m, "node_modules")), true)
        await m.remove()
        #expect(remover.received.withLock { $0 } == [["node_modules"]])
        #expect(remover.policies.withLock { $0 } == [.trash])
        guard case .report = m.phase else {
            Issue.record("expected report")
            return
        }
        #expect(m.rows.map(\.name) == ["big.bin"])
        #expect(m.currentSize == 150)
        #expect(m.tree?[0].size == 550)
        #expect(!m.hasSelection)
        #expect(m.selectedTotal == 0)
        m.closeReport()
        #expect(m.phase == .ready)
    }

    @Test func removingTheShownFolderGoesUp() async throws {
        let home = try Home()
        let m = await model(home)
        m.open(1)
        m.setChecked(try #require(row(m, "app")), true)
        m.open(2)
        await m.remove()
        #expect(m.current == 1)
        #expect(m.rows.isEmpty)
    }

    @Test func skippedItemsStaySelected() async throws {
        let home = try Home()
        let remover = RecordingRemover()
        remover.skip = ["big.bin"]
        let m = await model(home, remover: remover)
        m.open(1)
        m.open(2)
        m.setChecked(try #require(row(m, "big.bin")), true)
        await m.remove()
        #expect(m.checked == [4])
        #expect(m.selectedTotal == 150)
    }

    @Test func stoppedFirstScanReturnsToStart() async throws {
        let home = try Home()
        let m = SpaceLensModel(
            scanner: FakeSpaceScanner(tree: nil), remover: RecordingRemover(), roots: .spaceLens(home.paths),
            revealer: FakeRevealer(), paths: home.paths)
        await m.scan()
        #expect(m.phase == .idle)
        #expect(m.tree == nil)
    }
}
