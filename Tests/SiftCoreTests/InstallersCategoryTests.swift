import Foundation
import Testing

@testable import SiftCore

@Suite struct InstallersCategoryTests {
    private func setModified(_ url: URL, daysAgo: Double, from now: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-daysAgo * 86400)], ofItemAtPath: url.path)
    }

    private func names(_ findings: [Finding]) -> [String] {
        findings.map(\.url.lastPathComponent)
    }

    @Test func findsInstallersDirectlyInDownloadsAndDesktop() async throws {
        let fx = try Fixture()
        for path in [
            "home/Downloads/App.dmg", "home/Downloads/Tool.PKG", "home/Downloads/Old.mpkg", "home/Desktop/Xcode.xip",
            "home/Downloads/notes.txt", "home/Downloads/sub/Nested.dmg", "home/Documents/Elsewhere.dmg",
        ] {
            try fx.write(path, "x")
        }
        try fx.mkdir("home/Downloads/Bundle.pkg/Contents")
        try fx.symlink("home/Downloads/Link.dmg", to: fx.url("home/Downloads/App.dmg").path)
        let found = try await InstallersCategory().scan(paths: fx.paths)
        #expect(Set(names(found)) == ["App.dmg", "Tool.PKG", "Old.mpkg", "Xcode.xip"])
        #expect(found.allSatisfy { $0.sources == [.junk(categoryID: "installers")] && !$0.requiresRoot })
    }

    @Test func scopeAndPolicy() {
        let category = InstallersCategory()
        #expect(category.policy == .trash)
        #expect(category.removalScope == .largeFiles)
        #expect(!category.expandable)
    }

    @Test func preselectsOnlyOlderThanThirtyDays() async throws {
        let fx = try Fixture()
        let now = Date()
        let old = try fx.write("home/Downloads/old.dmg", "x")
        let fresh = try fx.write("home/Downloads/fresh.dmg", "x")
        try setModified(old, daysAgo: 45, from: now)
        try setModified(fresh, daysAgo: 3, from: now)
        let category = InstallersCategory(now: { now })
        let found = try await category.scan(paths: fx.paths)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0) })
        #expect(category.checkedByDefault(try #require(byName["old.dmg"]), running: []))
        #expect(!category.checkedByDefault(try #require(byName["fresh.dmg"]), running: []))
    }

    @Test func missingFoldersGiveNothing() async throws {
        let fx = try Fixture()
        #expect(try await InstallersCategory().scan(paths: fx.paths).isEmpty)
    }

    @Test func unreadableDownloadsIsNoAccess() async throws {
        let fx = try Fixture()
        let downloads = try fx.mkdir("home/Downloads")
        try fx.write("home/Downloads/App.dmg", "x")
        try fx.chmod(downloads, 0o000)
        await #expect(throws: JunkCategoryError.unreadable) { try await InstallersCategory().scan(paths: fx.paths) }
    }
}
