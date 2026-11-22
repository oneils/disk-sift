import Foundation
import Testing

@testable import SiftCore

@Suite struct IOSBackupsCategoryTests {
    let base = "home/Library/Application Support/MobileSync/Backup"

    private func info(_ fx: Fixture, _ id: String, _ dict: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try fx.write("\(base)/\(id)/Info.plist", data: data)
    }

    @Test func oneFindingPerBackupWithReadableName() async throws {
        let fx = try Fixture()
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        try info(fx, "00008030-AAA", ["Device Name": "Lex's iPhone", "Last Backup Date": date])
        try info(fx, "00008101-BBB", ["Device Name": "iPad"])
        try fx.mkdir("\(base)/00008110-CCC")
        try fx.write("\(base)/stray.txt")
        let found = try await IOSBackupsCategory().scan(paths: fx.paths)
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0) })
        #expect(byID.count == 3)
        #expect(
            byID["00008030-AAA"]?.displayName == "Lex's iPhone — \(date.formatted(date: .abbreviated, time: .omitted))")
        #expect(byID["00008101-BBB"]?.displayName == "iPad")
        #expect(byID["00008110-CCC"]?.displayName == nil)
        #expect(found.allSatisfy { !$0.requiresRoot })
    }

    @Test func corruptPlistFallsBackToFolderName() async throws {
        let fx = try Fixture()
        try fx.write("\(base)/X/Info.plist", "not a plist")
        let found = try await IOSBackupsCategory().scan(paths: fx.paths)
        #expect(found.count == 1)
        #expect(found[0].displayName == nil)
    }

    @Test func defaultsAndPolicy() async throws {
        let fx = try Fixture()
        try info(fx, "A", ["Device Name": "iPhone"])
        let category = IOSBackupsCategory()
        let found = try await category.scan(paths: fx.paths)
        #expect(!category.checkedByDefault(found[0], running: []))
        #expect(category.policy == .trash)
        #expect(!category.expandable)
        #expect(category.removalScope == .library)
    }

    @Test func missingBackupFolderGivesNothing() async throws {
        let fx = try Fixture()
        #expect(try await IOSBackupsCategory().scan(paths: fx.paths).isEmpty)
    }

    @Test func unreadableBackupFolderIsNoAccess() async throws {
        let fx = try Fixture()
        let dir = try fx.mkdir(base)
        try fx.chmod(dir, 0o000)
        await #expect(throws: JunkCategoryError.unreadable) { try await IOSBackupsCategory().scan(paths: fx.paths) }
    }

    @Test func libraryScopeAllowsBackupsButNotApplicationSupport() throws {
        let fx = try Fixture()
        let backup = try fx.mkdir("\(base)/A")
        let roots = RemovalRoots.make(fx.paths)
        #expect(roots.allows(try CanonicalPath.of(backup)))
        #expect(roots.allows(try CanonicalPath.of(fx.url(base))))  // inside Application Support, like any app folder
        #expect(!roots.allows(try CanonicalPath.of(fx.url("home/Library/Application Support"))))
    }
}
