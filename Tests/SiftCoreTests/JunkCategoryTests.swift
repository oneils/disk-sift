import Foundation
import Testing

@testable import SiftCore

struct JunkCategoryTests {
    @Test func userCachesExcludeDevOwnedAndMissing() async throws {
        let fx = try Fixture()
        try fx.write("home/Library/Caches/com.foo.App/a.bin", "x")
        try fx.write("home/Library/Caches/Homebrew/b", "x")
        try fx.write("home/Library/Caches/pip/c", "x")
        try fx.write("home/Library/Logs/foo.log", "x")
        let found = try await UserCachesCategory().scan(paths: fx.paths)
        let names = Set(found.map(\.url.lastPathComponent))
        #expect(names == ["com.foo.App", "foo.log"])
    }

    @Test func devScanSkipsMissingPaths() async throws {
        let fx = try Fixture()
        try fx.write("home/Library/Developer/Xcode/DerivedData/x", "x")
        try fx.write("home/.npm/_cacache/y", "y")
        let found = try await DevJunkCategory().scan(paths: fx.paths)
        #expect(Set(found.map(\.url.lastPathComponent)) == ["DerivedData", "_cacache"])
        #expect(found.allSatisfy { $0.sources == [.junk(categoryID: "devJunk")] })
    }

    @Test func defaultChecks() async throws {
        let fx = try Fixture()
        try fx.write("home/Library/Developer/Xcode/Archives/a", "x")
        try fx.write("home/Library/Developer/Xcode/DerivedData/d", "x")
        let dev = DevJunkCategory()
        let found = try await dev.scan(paths: fx.paths)
        for f in found {
            let expected = f.url.lastPathComponent != "Archives"
            #expect(dev.checkedByDefault(f, running: []) == expected)
        }

        try fx.write("home/Library/Caches/com.apple.Safari/a", "x")
        try fx.write("home/Library/Caches/org.mozilla.firefox/a", "x")
        try fx.write("home/Library/Caches/org.mozilla.firefox.helper/a", "x")
        try fx.write("home/Library/Caches/com.other/a", "x")
        let cat = UserCachesCategory()
        let running = [RunningApp(bundleID: "org.mozilla.firefox", bundleURL: nil, pid: 1)]
        let caches = try await cat.scan(paths: fx.paths)
        var checked: [String: Bool] = [:]
        for f in caches { checked[f.url.lastPathComponent] = cat.checkedByDefault(f, running: running) }
        #expect(checked["com.apple.Safari"] == false)
        #expect(checked["org.mozilla.firefox"] == false)
        #expect(checked["org.mozilla.firefox.helper"] == false)
        #expect(checked["com.other"] == true)
    }
}
