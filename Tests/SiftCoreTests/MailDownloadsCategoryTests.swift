import Foundation
import Testing

@testable import SiftCore

@Suite struct MailDownloadsCategoryTests {
    let base = "home/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"

    @Test func listsDownloadsAndPreselectsUnlessMailRuns() async throws {
        let fx = try Fixture()
        try fx.write("\(base)/1A2B/report.pdf", "x")
        try fx.write("\(base)/3C4D/photo.jpg", "x")
        let category = MailDownloadsCategory()
        let found = try await category.scan(paths: fx.paths)
        #expect(Set(found.map(\.url.lastPathComponent)) == ["1A2B", "3C4D"])
        #expect(category.policy == .delete)
        #expect(category.checkedByDefault(found[0], running: []))
        let mail = RunningApp(bundleID: "com.apple.mail", bundleURL: nil, pid: 9)
        #expect(!category.checkedByDefault(found[0], running: [mail]))
    }

    @Test func missingFolderGivesNothing() async throws {
        let fx = try Fixture()
        #expect(try await MailDownloadsCategory().scan(paths: fx.paths).isEmpty)
    }

    @Test func unreadableContainerIsNoAccess() async throws {
        let fx = try Fixture()
        let dir = try fx.mkdir(base)
        try fx.chmod(dir, 0o000)
        await #expect(throws: JunkCategoryError.unreadable) { try await MailDownloadsCategory().scan(paths: fx.paths) }
    }

    @Test func libraryScopeAllowsMailDownloads() throws {
        let fx = try Fixture()
        let item = try fx.mkdir("\(base)/1A2B")
        #expect(RemovalRoots.make(fx.paths).allows(try CanonicalPath.of(item)))
    }
}
