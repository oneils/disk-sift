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

    @Test func progressReportedPerItem() async throws {
        let fx = try Fixture()
        let file1 = try fx.write("home/Library/Caches/com.foo/1", "a")
        let file2 = try fx.write("home/Library/Caches/com.foo/2", "bb")
        let f1 = Finding(url: file1, size: 10, confidence: .high, sources: [.libraryPath])
        let f2 = Finding(url: file2, size: 20, confidence: .high, sources: [.libraryPath])

        let steps = OSAllocatedUnfairLock<[RemovalProgressState]>(initialState: [])
        let report = await remover(fx).remove([f1, f2], policy: .delete) { state in
            steps.withLock { $0.append(state) }
        }

        #expect(report.removed.count == 2)
        #expect(!report.stopped)
        #expect(report.unprocessed.isEmpty)
        let recorded = steps.withLock { $0 }
        #expect(recorded.count == 2)
        #expect(recorded[0].completed == 0 && recorded[0].total == 2 && recorded[0].processedBytes == 0)
        #expect(recorded[0].current.url == file1)
        #expect(recorded[1].completed == 1 && recorded[1].total == 2 && recorded[1].processedBytes == 10)
        #expect(recorded[1].current.url == file2)
    }

    @Test func stoppingLeavesRemainingUnprocessed() async throws {
        let fx = try Fixture()
        let file1 = try fx.write("home/Library/Caches/com.foo/1", "a")
        let file2 = try fx.write("home/Library/Caches/com.foo/2", "b")
        let f1 = Finding(url: file1, size: 10, confidence: .high, sources: [.libraryPath])
        let f2 = Finding(url: file2, size: 20, confidence: .high, sources: [.libraryPath])

        let rem = remover(fx)
        let task = Task {
            await rem.remove([f1, f2], policy: .delete) { state in
                if state.completed == 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let report = await task.value

        #expect(report.removed.count == 1)
        #expect(report.removed.first?.url == file1)
        #expect(report.unprocessed == [f2])
        #expect(report.stopped)
        #expect(!FileManager.default.fileExists(atPath: file1.path))
        #expect(FileManager.default.fileExists(atPath: file2.path))
    }

    @Test func removeStreamYieldsProgressAndCompletion() async throws {
        let fx = try Fixture()
        let file1 = try fx.write("home/Library/Caches/com.foo/1", "a")
        let f1 = Finding(url: file1, size: 10, confidence: .high, sources: [.libraryPath])

        var receivedStates: [RemovalProgressState] = []
        var finalReport: RemovalReport?
        for await event in remover(fx).removeStream([f1], policy: .delete) {
            switch event {
            case .step(let s): receivedStates.append(s)
            case .completed(let r): finalReport = r
            }
        }
        #expect(receivedStates.count == 1)
        #expect(finalReport?.removed.count == 1)
    }
    @Test func cancelledBeforeStartLeavesEverythingUntouched() async throws {
        let fx = try Fixture()
        let file = try fx.write("home/Library/Caches/com.foo/file")
        let item = finding(file)
        let rem = remover(fx)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await rem.remove([item], policy: .delete) { _ in
                Issue.record("Cancelled removal must not start an item")
            }
        }
        let report = await task.value
        #expect(report.stopped)
        #expect(report.unprocessed == [item])
        #expect(report.removed.isEmpty && report.skipped.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func progressCountsFailuresButNotTheirBytes() async throws {
        let fx = try Fixture()
        let missing = finding(fx.paths.home.appendingPathComponent("Library/Caches/missing"))
        let file = try fx.write("home/Library/Caches/com.foo/file")
        let steps = OSAllocatedUnfairLock<[RemovalProgressState]>(initialState: [])
        let report = await remover(fx).remove([missing, finding(file)], policy: .delete) { state in
            steps.withLock { $0.append(state) }
        }
        #expect(report.skipped.map(\.reason) == [.vanished])
        #expect(report.removed.map(\.url) == [file])
        #expect(steps.withLock { $0.last?.completed } == 1)
        #expect(steps.withLock { $0.last?.processedBytes } == 0)
    }

    @Test func stoppingDuringLastItemStillReportsCompletion() async throws {
        let fx = try Fixture()
        let file = try fx.write("home/Library/Caches/com.foo/file")
        let rem = remover(fx)
        let item = finding(file)
        let task = Task {
            await rem.remove([item], policy: .delete) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let report = await task.value
        #expect(report.removed.map(\.url) == [file])
        #expect(!report.stopped)
        #expect(report.unprocessed.isEmpty)
    }

}

@Suite struct LargeFilesRemoverTests {
    private func finding(_ url: URL) -> Finding {
        Finding(url: url, size: 1, confidence: .high, sources: [.largeFile])
    }

    /// Built exactly as the app does: no flags beyond the scope.
    private func remover(_ fx: Fixture, _ trasher: FakeTrasher) -> Remover {
        Remover(roots: .largeFiles(fx.paths), trasher: trasher)
    }

    @Test func regularFileInHomeIsTrashed() throws {
        let fx = try Fixture()
        let file = try fx.write("home/Downloads/movie.mkv", "x")
        let trasher = FakeTrasher()
        let report = remover(fx, trasher).remove([finding(file)], policy: .trash)
        #expect(report.removed.map(\.url) == [file])
        #expect(trasher.trashed.map(\.path) == [file.path])
    }

    @Test func directoryRefused() throws {
        let fx = try Fixture()
        let dir = try fx.mkdir("home/Documents/Project")
        try fx.write("home/Documents/Project/a.txt")
        let trasher = FakeTrasher()
        let report = remover(fx, trasher).remove([finding(dir)], policy: .trash)
        #expect(report.skipped == [SkippedItem(url: dir, reason: .notAFile)])
        #expect(trasher.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func deniedPathsRefused() throws {
        let fx = try Fixture()
        let inLibrary = try fx.write("home/Library/Caches/big.bin")
        let inApp = try fx.write("home/Desktop/X.app/Contents/Resources/big.bin")
        let inGit = try fx.write("home/code/r/.git/objects/p.pack")
        let trasher = FakeTrasher()
        let report = remover(fx, trasher).remove([inLibrary, inApp, inGit].map(finding), policy: .trash)
        #expect(report.skipped.map(\.reason) == [.outsideRoots, .outsideRoots, .outsideRoots])
        #expect(trasher.trashed.isEmpty)
    }

    @Test func permanentDeletionRefusedForEverything() throws {
        let fx = try Fixture()
        let file = try fx.write("home/Downloads/a.bin", "x")
        let trasher = FakeTrasher()
        let r = remover(fx, trasher)
        let report = r.remove([finding(file)], policy: .delete)
        #expect(report.skipped == [SkippedItem(url: file, reason: .policyNotAllowed)])
        #expect(report.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func permanentDeletionRefusedAsync() async throws {
        let fx = try Fixture()
        let file = try fx.write("home/Downloads/a.bin", "x")
        let report = await remover(fx, FakeTrasher()).remove([finding(file)], policy: .delete, onProgress: nil)
        #expect(report.skipped.map(\.reason) == [.policyNotAllowed])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func symlinkRefusedAndTargetUntouched() throws {
        let fx = try Fixture()
        let target = try fx.write("tmp/outside.bin", "keep")
        let link = try fx.symlink("home/Downloads/link.bin", to: target.path)
        let trasher = FakeTrasher()
        let report = remover(fx, trasher).remove([finding(link)], policy: .trash)
        #expect(report.skipped == [SkippedItem(url: link, reason: .notAFile)])
        #expect(trasher.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    /// Documented on purpose: a hard link is a regular file in the allowed folder; trashing it removes
    /// only that name, the file under ~/Library keeps its other link.
    @Test func hardLinkToLibraryFileTrashesOnlyTheLink() throws {
        let fx = try Fixture()
        let original = try fx.write("home/Library/Application Support/data.bin", "data")
        let link = fx.url("home/Downloads/data.bin")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: original, to: link)
        let trasher = FakeTrasher()
        let report = remover(fx, trasher).remove([finding(link)], policy: .trash)
        #expect(report.removed.map(\.url) == [link])
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try String(contentsOf: original, encoding: .utf8) == "data")
    }
}
