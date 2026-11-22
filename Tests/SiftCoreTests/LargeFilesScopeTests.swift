import Foundation
import Testing

@testable import SiftCore

@Suite struct LargeFilesScopeTests {
    private func allows(_ fx: Fixture, _ relative: String) throws -> Bool {
        RemovalRoots.largeFiles(fx.paths).allows(try CanonicalPath.of(fx.url(relative)))
    }

    @Test func filesInUserFoldersAreAllowed() throws {
        let fx = try Fixture()
        for path in ["home/Downloads/movie.mkv", "home/Movies/a/b.mov", "home/.ollama/models/blob", "home/x.iso"] {
            try fx.write(path)
            #expect(try allows(fx, path), "\(path)")
        }
    }

    @Test func deniedHomeChildren() throws {
        let fx = try Fixture()
        for path in [
            "home/Library/Caches/big", "home/Library/Mobile Documents/com~apple~CloudDocs/x", "home/.Trash/old.dmg",
            "home/Applications/Foo.app",
        ] {
            try fx.write(path)
            #expect(try !allows(fx, path), "\(path)")
        }
    }

    @Test func insidePackagesAndGitDenied() throws {
        let fx = try Fixture()
        for path in [
            "home/Desktop/X.app/Contents/MacOS/x", "home/Pictures/Photos Library.photoslibrary/originals/a.heic",
            "home/code/repo/.git/objects/pack/p.pack", "home/VMs/Linux.utm/Data/disk.qcow2",
            "home/Disk.SPARSEBUNDLE/bands/0",
        ] {
            try fx.write(path)
            #expect(try !allows(fx, path), "\(path)")
        }
        // a sibling of a package or a repo stays allowed
        try fx.write("home/code/repo/build.tar")
        #expect(try allows(fx, "home/code/repo/build.tar"))
    }

    @Test func homeItselfAndOutsideDenied() throws {
        let fx = try Fixture()
        let roots = RemovalRoots.largeFiles(fx.paths)
        #expect(!roots.allows(try CanonicalPath.of(fx.paths.home)))
        try fx.write("tmp/elsewhere.bin")
        #expect(try !allows(fx, "tmp/elsewhere.bin"))
        try fx.write("Library/Caches/sys")
        #expect(try !allows(fx, "Library/Caches/sys"))
    }

    @Test func caseInsensitive() throws {
        let fx = try Fixture()
        try fx.write("home/Library/Caches/x")
        #expect(try !allows(fx, "home/LIBRARY/Caches/x"))
        try fx.write("home/a/Repo/.GIT/x")
        #expect(try !allows(fx, "home/a/Repo/.GIT/x"))
    }

    @Test func symlinkedDirectoryIntoLibraryRefused() throws {
        let fx = try Fixture()
        try fx.write("home/Library/Application Support/big.db")
        try fx.symlink(
            "home/Downloads/support", to: fx.paths.library.appendingPathComponent("Application Support").path)
        // the parent chain is resolved, so this is really ~/Library/Application Support/big.db
        #expect(try !allows(fx, "home/Downloads/support/big.db"))
    }

    @Test func otherVolumeDenied() throws {
        let fx = try Fixture()
        try fx.write("home/Downloads/a.bin")
        let home = RemovalRoots.canonicalRoot(fx.paths.home)
        var st = stat()
        #expect(lstat(home.path, &st) == 0)
        let path = try CanonicalPath.of(fx.url("home/Downloads/a.bin"))
        #expect(!LargeFilesScope(home: home, homeDevice: st.st_dev).isDenied(path))
        #expect(LargeFilesScope(home: home, homeDevice: st.st_dev &+ 1).isDenied(path))
        #expect(LargeFilesScope(home: home, homeDevice: nil).isDenied(path))
    }

    @Test func libraryScopeUnchanged() throws {
        let fx = try Fixture()
        let library = RemovalRoots.make(fx.paths)
        #expect(library.kind == .library)
        #expect(!library.filesOnly && !library.trashOnly)
        try fx.write("home/Downloads/a.bin")
        #expect(!library.allows(try CanonicalPath.of(fx.url("home/Downloads/a.bin"))))
        let large = RemovalRoots.largeFiles(fx.paths)
        #expect(large.filesOnly && large.trashOnly)
    }

    @Test func scannerSkipRules() throws {
        let fx = try Fixture()
        let scope = LargeFilesScope(paths: fx.paths)
        let home = fx.paths.home
        var st = stat()
        #expect(lstat(home.path, &st) == 0)
        let dev = st.st_dev
        try fx.mkdir("home/Downloads")
        try fx.mkdir("home/Library/Caches")
        #expect(!scope.shouldSkipDirectory(home, isPackage: false, device: dev))
        #expect(!scope.shouldSkipDirectory(fx.url("home/Downloads"), isPackage: false, device: dev))
        #expect(scope.shouldSkipDirectory(fx.url("home/Library"), isPackage: false, device: dev))
        #expect(scope.shouldSkipDirectory(fx.url("home/Downloads"), isPackage: true, device: dev))
        #expect(scope.shouldSkipDirectory(fx.url("home/Downloads"), isPackage: false, device: dev &+ 1))
        try fx.mkdir("home/code/r/.git")
        #expect(scope.shouldSkipDirectory(fx.url("home/code/r/.git"), isPackage: false, device: dev))
        try fx.mkdir("home/VMs/Win.pvm")
        #expect(scope.shouldSkipDirectory(fx.url("home/VMs/Win.pvm"), isPackage: false, device: dev))
    }
}
