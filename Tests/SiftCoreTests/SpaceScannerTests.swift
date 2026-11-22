import Foundation
import Testing

@testable import SiftCore

@Suite struct SpaceScannerTests {
    private let big = String(repeating: "x", count: 300_000)

    private func scan(_ fx: Fixture, minimum: Int64 = 100_000) async throws -> SpaceTree {
        try await SpaceScanner(root: fx.paths.home, minimumFileSize: minimum).scan()
    }

    private func child(_ tree: SpaceTree, _ parent: Int32, _ name: String) -> Int32? {
        tree[parent].children.first { tree[$0].name == name }
    }

    private func path(_ tree: SpaceTree, _ names: String...) -> Int32? {
        var current: Int32 = 0
        for name in names {
            guard let next = child(tree, current, name) else { return nil }
            current = next
        }
        return current
    }

    @Test func sizesRollUpAndSmallFilesAreSummed() async throws {
        let fx = try Fixture()
        try fx.write("home/Projects/app/big.bin", big)
        try fx.write("home/Projects/app/a.txt", "a")
        try fx.write("home/Projects/app/b.txt", "b")
        try fx.write("home/Projects/notes.md", "n")
        let tree = try await scan(fx)
        let app = try #require(path(tree, "Projects", "app"))
        let projects = try #require(path(tree, "Projects"))
        let bigFile = try #require(child(tree, app, "big.bin"))
        #expect(tree[bigFile].kind == .file)
        #expect(tree[bigFile].size >= 300_000)
        let other = try #require(tree[app].children.first { tree[$0].kind == .otherFiles(count: 2) })
        #expect(tree[other].size > 0)
        // a folder is its own blocks plus everything below
        let below = tree[app].children.reduce(Int64(0)) { $0 + tree[$1].size }
        #expect(tree[app].size >= below)
        #expect(tree[projects].size >= tree[app].size)
        #expect(tree[0].size >= tree[projects].size)
        #expect(tree.url(of: bigFile).path == fx.url("home/Projects/app/big.bin").path)
        #expect(tree.url(of: other).path == fx.url("home/Projects/app").path)
    }

    @Test func childrenAreLargestFirstWithOtherFilesLast() async throws {
        let fx = try Fixture()
        try fx.write("home/small/x", "x")
        try fx.write("home/large/big.bin", big)
        try fx.write("home/loose.txt", "x")
        let tree = try await scan(fx)
        let names = tree.children(of: 0).map { tree[$0].kind == .otherFiles(count: 1) ? "*" : tree[$0].name }
        #expect(names.first == "large")
        #expect(names.last == "*")
    }

    @Test func packagesAndGitAreSizedWholeAndNotEntered() async throws {
        let fx = try Fixture()
        try fx.write("home/Tools/My.app/Contents/MacOS/bin", big)
        try fx.write("home/repo/.git/objects/pack", big)
        let tree = try await scan(fx)
        let app = try #require(path(tree, "Tools", "My.app"))
        #expect(tree[app].kind == .package)
        #expect(tree[app].children.isEmpty)
        #expect(tree[app].size >= 300_000)
        #expect(!tree[app].isEnterable)
        let git = try #require(path(tree, "repo", ".git"))
        #expect(tree[git].kind == .package)
        #expect(tree[git].size >= 300_000)
    }

    @Test func hardLinksCountOnceAndSymlinksAreNotFollowed() async throws {
        let fx = try Fixture()
        let file = try fx.write("home/a/big.bin", big)
        try fx.mkdir("home/b")
        try FileManager.default.linkItem(at: file, to: fx.url("home/b/big-link.bin"))
        try fx.write("tmp/outside/huge.bin", big + big)
        try fx.symlink("home/link", to: fx.url("tmp/outside").path)
        let tree = try await scan(fx)
        let a = try #require(path(tree, "a"))
        let b = try #require(path(tree, "b"))
        #expect(tree[a].size + tree[b].size < 600_000)
        #expect(path(tree, "link", "huge.bin") == nil)
        #expect(tree[0].size < 600_000)
    }

    @Test func unreadableFolderIsMarked() async throws {
        let fx = try Fixture()
        try fx.write("home/locked/secret.bin", big)
        try fx.chmod("home/locked", 0o000)
        let tree = try await scan(fx)
        let locked = try #require(path(tree, "locked"))
        #expect(tree[locked].inaccessible)
        #expect(tree[0].inaccessible)
    }

    @Test func removeDetachesAndShrinksAncestors() async throws {
        let fx = try Fixture()
        try fx.write("home/Projects/app/big.bin", big)
        try fx.write("home/Projects/keep/k", "k")
        var tree = try await scan(fx)
        let app = try #require(path(tree, "Projects", "app"))
        let projects = try #require(path(tree, "Projects"))
        let (rootBefore, projectsBefore, appSize) = (tree[0].size, tree[projects].size, tree[app].size)
        tree.remove(app)
        #expect(!tree[projects].children.contains(app))
        #expect(tree[projects].size == projectsBefore - appSize)
        #expect(tree[0].size == rootBefore - appSize)
        #expect(tree.isAncestor(projects, of: app))
        #expect(!tree.isAncestor(app, of: projects))
        #expect(tree.ancestry(of: app) == [0, projects, app])
    }

    @Test func cancellationStops() async throws {
        let fx = try Fixture()
        for i in 0..<5000 { try fx.write("home/d\(i % 50)/f\(i)", "x") }
        let scanner = SpaceScanner(root: fx.paths.home)
        let task = Task { try await scanner.scan() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct SpaceLensRemovalRootsTests {
    @Test func foldersAllowedOutsideTheDenyListTrashOnly() throws {
        let fx = try Fixture()
        let roots = RemovalRoots.spaceLens(fx.paths)
        #expect(!roots.filesOnly)
        #expect(roots.trashOnly)
        let folder = try fx.mkdir("home/Projects/node_modules")
        #expect(roots.allows(try CanonicalPath.of(folder)))
        let app = try fx.mkdir("home/Tools/My.app")
        #expect(roots.allows(try CanonicalPath.of(app)))  // the package itself, not inside it
        #expect(!roots.allows(try CanonicalPath.of(try fx.mkdir("home/Tools/My.app/Contents"))))
        #expect(!roots.allows(try CanonicalPath.of(try fx.mkdir("home/Library/Caches"))))
        #expect(!roots.allows(try CanonicalPath.of(fx.paths.home)))
        #expect(RemovalRoots.largeFiles(fx.paths).filesOnly)
    }

    @Test func removerTrashesFoldersAndRefusesDeletion() throws {
        let fx = try Fixture()
        let folder = try fx.mkdir("home/Projects/node_modules")
        try fx.write("home/Projects/node_modules/pkg/index.js", "x")
        let trasher = FakeTrasher()
        let remover = Remover(roots: .spaceLens(fx.paths), trasher: trasher)
        let finding = Finding(url: folder, size: 1, confidence: .high, sources: [.largeFile])
        #expect(remover.remove([finding], policy: .delete).skipped.first?.reason == .policyNotAllowed)
        #expect(remover.remove([finding], policy: .trash).removed.count == 1)
        #expect(trasher.trashed.map(\.lastPathComponent) == ["node_modules"])
    }
}
