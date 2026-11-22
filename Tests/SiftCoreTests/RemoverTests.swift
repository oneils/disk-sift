import Foundation
import Testing
import os

@testable import SiftCore

final class FakeTrasher: Trasher, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [URL]())
    var error: (any Error)?
    /// Paths that fail instead of being trashed.
    var failing: Set<String> = []

    var trashed: [URL] { state.withLock { $0 } }

    func trash(_ url: URL) throws {
        if let error, failing.isEmpty || failing.contains(url.path) { throw error }
        state.withLock { $0.append(url) }
        try FileManager.default.removeItem(at: url)
    }
}

@Suite struct RemoverTests {
    private func finding(_ url: URL) -> Finding {
        Finding(url: url, size: 1, confidence: .high, sources: [.libraryPath])
    }

    private func remover(_ fx: Fixture, _ trasher: FakeTrasher = FakeTrasher()) -> Remover {
        Remover(roots: RemovalRoots.make(fx.paths), trasher: trasher)
    }

    // MARK: roots

    @Test func everyScanDirItselfIsRejected() throws {
        let fx = try Fixture()
        let roots = RemovalRoots.make(fx.paths)
        for dir in ScanLocations.leftoverDirs(fx.paths) + [fx.paths.applications, fx.paths.userApplications] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #expect(!roots.allows(try CanonicalPath.of(dir)), "\(dir.path)")
        }
    }

    @Test func protectedLibraryFoldersRejected() throws {
        let fx = try Fixture()
        for name in ["CloudStorage", "Mobile Documents", "Keychains", "Mail", "Messages"] {
            let url = try fx.mkdir("home/Library/\(name)/x")
            let report = remover(fx).remove([finding(url)], policy: .delete)
            #expect(report.skipped == [SkippedItem(url: url, reason: .outsideRoots)])
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func dotDotTraversalRejected() throws {
        let fx = try Fixture()
        let victim = try fx.write("home/Documents/keep.txt")
        try fx.mkdir("home/Library/Caches")
        let sneaky = fx.url("home/Library/Caches/../../Documents/keep.txt")
        let report = remover(fx).remove([finding(sneaky)], policy: .delete)
        #expect(report.skipped.first?.reason == .outsideRoots)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func symlinkedMiddleDirPointingOutsideRejected() throws {
        let fx = try Fixture()
        let victim = try fx.write("home/Documents/sub/keep.txt")
        try fx.mkdir("home/Library/Caches")
        try fx.symlink("home/Library/Caches/X", to: fx.url("home/Documents").path)
        let url = fx.url("home/Library/Caches/X/sub")
        let report = remover(fx).remove([finding(url)], policy: .delete)
        #expect(report.skipped.first?.reason == .outsideRoots)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func devJunkPathsAndLeftoverChildrenPass() throws {
        let fx = try Fixture()
        let roots = RemovalRoots.make(fx.paths)
        for url in DevJunkCategory.paths(fx.paths) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            #expect(roots.allows(try CanonicalPath.of(url)), "\(url.path)")
        }
        for dir in ScanLocations.leftoverDirs(fx.paths) {
            let child = dir.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            #expect(roots.allows(try CanonicalPath.of(child)), "\(child.path)")
        }
    }

    // MARK: removal

    @Test func symlinkRemovedTargetIntact() throws {
        let fx = try Fixture()
        let target = try fx.write("home/Documents/keep.txt", "data")
        let link = try fx.symlink("home/Library/Caches/link", to: fx.url("home/Documents").path)
        let report = remover(fx).remove([finding(link)], policy: .delete)
        #expect(report.removed.map(\.url) == [link])
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func trashUsesTrasher() throws {
        let fx = try Fixture()
        let file = try fx.write("home/Library/Caches/com.foo/x")
        let dir = file.deletingLastPathComponent()
        let trasher = FakeTrasher()
        let report = remover(fx, trasher).remove([finding(dir)], policy: .trash)
        #expect(trasher.trashed == [dir])
        #expect(report.removed == [RemovedItem(url: dir, size: 1)])
    }

    @Test func deleteRemoves() throws {
        let fx = try Fixture()
        let file = try fx.write("home/Library/Caches/com.foo/x")
        let dir = file.deletingLastPathComponent()
        let trasher = FakeTrasher()
        let report = remover(fx, trasher).remove([finding(dir)], policy: .delete)
        #expect(report.removed.count == 1)
        #expect(trasher.trashed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func readOnlyTreeDeleted() throws {
        let fx = try Fixture()
        let outside = try fx.write("home/outside.txt", "o")
        try fx.chmod(outside, 0o444)
        let base = "home/go/pkg/mod/github.com/x@v1"
        let file = try fx.write("\(base)/file.go", "package x")
        let inner = try fx.write("\(base)/sub/inner.go", "package y")
        try fx.symlink("\(base)/link", to: outside.path)
        let mod = fx.url("home/go/pkg/mod")
        // read-only the way the Go module cache is: files 0444, directories 0555
        try fx.chmod(file, 0o444)
        try fx.chmod(inner, 0o444)
        try fx.chmod(fx.url("\(base)/sub"), 0o555)
        try fx.chmod(fx.url(base), 0o555)
        let report = remover(fx).remove([finding(mod)], policy: .delete)
        #expect(report.skipped.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: mod.path))
        var st = stat()
        #expect(lstat(outside.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o444)
    }

    @Test func vanishedFileSkipped() throws {
        let fx = try Fixture()
        try fx.mkdir("home/Library/Caches")
        let url = fx.url("home/Library/Caches/gone")
        let report = remover(fx).remove([finding(url)], policy: .delete)
        #expect(report.skipped == [SkippedItem(url: url, reason: .vanished)])
    }

    @Test func permissionErrorSkippedOthersRemoved() throws {
        let fx = try Fixture()
        let bad = try fx.write("home/Library/Caches/bad")
        let good = try fx.write("home/Library/Caches/good")
        let trasher = FakeTrasher()
        trasher.error = POSIXError(.EACCES)
        trasher.failing = [bad.path]
        let report = remover(fx, trasher).remove([finding(bad), finding(good)], policy: .trash)
        #expect(report.skipped == [SkippedItem(url: bad, reason: .permissionDenied)])
        #expect(report.removed.map(\.url) == [good])
    }

    @Test func busyMapsToInUse() throws {
        let fx = try Fixture()
        let file = try fx.write("home/Library/Caches/busy")
        let trasher = FakeTrasher()
        trasher.error = POSIXError(.EBUSY)
        let report = remover(fx, trasher).remove([finding(file)], policy: .trash)
        #expect(report.skipped == [SkippedItem(url: file, reason: .inUse)])
    }

    @Test func notRemovableByUserNeedsAdmin() throws {
        let fx = try Fixture()
        let locked = try fx.write("home/Library/Caches/locked/f")
        let free = try fx.write("home/Library/Caches/free")
        try fx.chmod(fx.url("home/Library/Caches/locked"), 0o555)
        let trasher = FakeTrasher()
        // a file in a read-only directory cannot be removed, the directory itself can't be trashed either
        let report = remover(fx, trasher).remove([finding(locked), finding(free)], policy: .trash)
        #expect(report.skipped == [SkippedItem(url: locked, reason: .needsAdmin)])
        #expect(report.removed.map(\.url) == [free])
        #expect(FileManager.default.fileExists(atPath: locked.path))
    }
}
