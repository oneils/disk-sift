import Foundation
import Testing

@testable import SiftCore

@Suite struct SiftPathsTests {
    @Test func livePaths() {
        let live = SiftPaths.live
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(live.home.path == home.path)
        #expect(live.library.path == home.appendingPathComponent("Library").path)
        #expect(live.userApplications.path == home.appendingPathComponent("Applications").path)
        #expect(live.systemLibrary.path == "/Library")
        #expect(live.applications.path == "/Applications")
        #expect(live.tmp.path == FileManager.default.temporaryDirectory.path)
    }

    @Test func rootLayout() {
        let paths = SiftPaths(root: URL(fileURLWithPath: "/r"))
        #expect(paths.home.path == "/r/home")
        #expect(paths.library.path == "/r/home/Library")
        #expect(paths.systemLibrary.path == "/r/Library")
        #expect(paths.applications.path == "/r/Applications")
        #expect(paths.userApplications.path == "/r/home/Applications")
        #expect(paths.tmp.path == "/r/tmp")
    }

    @Test func fixturePathsAreCanonical() throws {
        let fixture = try Fixture()
        let all = [
            fixture.root, fixture.paths.home, fixture.paths.library, fixture.paths.systemLibrary,
            fixture.paths.applications, fixture.paths.userApplications, fixture.paths.tmp,
        ]
        for url in all {
            #expect(canonical(url.path) == url.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(!fixture.root.path.hasPrefix("/var/"))
    }

    @Test func fixtureRestoresPermissionsAndCleansUp() throws {
        var root: URL?
        do {
            let fixture = try Fixture()
            root = fixture.root
            let dir = try fixture.mkdir("home/Library/Caches/locked")
            try fixture.write("home/Library/Caches/locked/file", "x")
            try fixture.chmod(dir, 0o000)
            #expect(!FileManager.default.isReadableFile(atPath: dir.path))
        }
        let removed = try #require(root)
        #expect(!FileManager.default.fileExists(atPath: removed.path))
    }

    @Test func fixtureMakesApps() throws {
        let fixture = try Fixture()
        let app = try fixture.makeApp(bundleID: "com.foo.App", name: "Foo", nested: ["com.foo.App.Helper"])
        #expect(app.path == fixture.paths.applications.appendingPathComponent("Foo.app").path)
        let info = try #require(NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")))
        #expect(info["CFBundleIdentifier"] as? String == "com.foo.App")
        let helper = app.appendingPathComponent(
            "Contents/Library/LoginItems/com.foo.App.Helper.app/Contents/Info.plist")
        let helperInfo = try #require(NSDictionary(contentsOf: helper))
        #expect(helperInfo["CFBundleIdentifier"] as? String == "com.foo.App.Helper")

        let link = try fixture.symlink("home/link", to: app.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == app.path)
    }

    private func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
