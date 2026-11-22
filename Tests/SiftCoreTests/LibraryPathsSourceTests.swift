import Foundation
import Testing

@testable import SiftCore

@Suite struct LibraryPathsSourceTests {
    private func app(
        _ fx: Fixture, id: String = "com.foo.bar", name: String = "Bar", nested: [String] = [],
        signing: SigningInfo = .unsigned
    ) -> AppInfo {
        AppInfo(
            url: fx.paths.applications.appendingPathComponent("\(name).app"), bundleID: id, name: name,
            signing: signing, nestedBundleIDs: nested)
    }

    private func scan(
        _ fx: Fixture, _ app: AppInfo, installed: Set<String> = [], fda: Bool = true
    ) async throws -> [String: Finding] {
        let source = LibraryPathsSource(
            installed: FakeInstalledApps(bundleIDs: installed), hasFullDiskAccess: { _ in fda })
        let found = try await source.findings(for: app, paths: fx.paths)
        return Dictionary(
            uniqueKeysWithValues: found.map { ($0.url.path.replacingOccurrences(of: fx.root.path + "/", with: ""), $0) }
        )
    }

    @Test func highConfidenceMatches() async throws {
        let fx = try Fixture()
        try fx.mkdir("home/Library/Application Support/com.foo.bar")
        try fx.mkdir("home/Library/Caches/com.foo.bar.helper")
        try fx.mkdir("home/Library/Application Support/com.foo.bar.nested.sub")
        try fx.write("home/Library/Preferences/com.foo.bar.plist")
        try fx.write("home/Library/Preferences/ByHost/com.foo.bar.ABC-123.plist")
        try fx.mkdir("home/Library/Saved Application State/com.foo.bar.savedState")
        try fx.mkdir("home/Library/Group Containers/group.foo.shared")
        let info = app(fx, nested: ["com.foo.bar.nested"], signing: SigningInfo(appGroups: ["group.foo.shared"]))
        let found = try await scan(fx, info)
        #expect(found.count == 7)
        for finding in found.values {
            #expect(finding.confidence == .high)
            #expect(!finding.requiresRoot)
        }
        #expect(found["home/Library/Group Containers/group.foo.shared"]?.sources == [.groupContainer])
        #expect(found["home/Library/Preferences/com.foo.bar.plist"]?.sources == [.libraryPath])
        #expect(found["home/Library/Preferences/com.foo.bar.plist"]?.evidence == [.bundleIDName])
        let group = found["home/Library/Group Containers/group.foo.shared"]
        #expect(group?.evidence == [.appGroup])
        #expect(group?.isShared == true)
    }

    @Test func teamPrefixedGroupNotInEntitlementIsLow() async throws {
        let fx = try Fixture()
        try fx.mkdir("home/Library/Group Containers/UBF8T346G9.Office")
        let found = try await scan(fx, app(fx, signing: SigningInfo(teamID: "UBF8T346G9")))
        #expect(found["home/Library/Group Containers/UBF8T346G9.Office"]?.confidence == .low)
        #expect(found["home/Library/Group Containers/UBF8T346G9.Office"]?.evidence == [.teamPrefix])
    }

    @Test func otherInstalledAppDowngrades() async throws {
        let fx = try Fixture()
        try fx.mkdir("home/Library/Application Support/com.foo.bar.Lite")
        try fx.mkdir("home/Library/Application Support/com.foo.bar")
        let found = try await scan(fx, app(fx), installed: ["com.foo.bar.lite"])
        #expect(found["home/Library/Application Support/com.foo.bar.Lite"]?.confidence == .low)
        #expect(
            found["home/Library/Application Support/com.foo.bar.Lite"]?.evidence == [.bundleIDName, .otherAppInstalled])
        #expect(found["home/Library/Application Support/com.foo.bar"]?.confidence == .high)
        #expect(found["home/Library/Application Support/com.foo.bar"]?.isShared == false)
    }

    @Test func notInstalledSuffixStaysHigh() async throws {
        let fx = try Fixture()
        try fx.mkdir("home/Library/Application Support/com.foo.bar.Lite")
        let found = try await scan(fx, app(fx))
        #expect(found["home/Library/Application Support/com.foo.bar.Lite"]?.confidence == .high)
    }

    @Test func similarBundleIDNotMatched() async throws {
        let fx = try Fixture()
        try fx.mkdir("home/Library/Application Support/com.foo.barbaz")
        try fx.write("home/Library/Preferences/com.foo.barbaz.plist")
        #expect(try await scan(fx, app(fx)).isEmpty)
    }

    @Test func shortNameIgnoredLongNameIsLow() async throws {
        let fx = try Fixture()
        try fx.mkdir("home/Library/Application Support/Arc")
        try fx.mkdir("home/Library/Application Support/Code")
        let short = try await scan(fx, app(fx, id: "company.thebrowser.Browser", name: "Arc"))
        #expect(short.isEmpty)
        let long = try await scan(fx, app(fx, id: "com.microsoft.VSCode", name: "Code"))
        #expect(long.count == 1)
        #expect(long["home/Library/Application Support/Code"]?.confidence == .low)
    }

    @Test func containersNotReadWithoutFDA() async throws {
        let fx = try Fixture()
        try fx.mkdir("home/Library/Containers/com.foo.bar")
        try fx.mkdir("home/Library/Group Containers/group.foo.shared")
        try fx.mkdir("home/Library/Caches/com.foo.bar")
        let info = app(fx, signing: SigningInfo(appGroups: ["group.foo.shared"]))
        let without = try await scan(fx, info, fda: false)
        #expect(Set(without.keys) == ["home/Library/Caches/com.foo.bar"])
        let with = try await scan(fx, info, fda: true)
        #expect(with.count == 3)
    }

    @Test func readOnlyParentRequiresRoot() async throws {
        let fx = try Fixture()
        try fx.mkdir("Library/Application Support/com.foo.bar")
        try fx.mkdir("home/Library/Application Support/com.foo.bar")
        try fx.chmod("Library/Application Support", 0o555)
        let found = try await scan(fx, app(fx))
        #expect(found["Library/Application Support/com.foo.bar"]?.requiresRoot == true)
        #expect(found["home/Library/Application Support/com.foo.bar"]?.requiresRoot == false)
    }

    @Test func launchDirsAreLeftToLaunchItemsSource() async throws {
        let fx = try Fixture()
        try fx.write("home/Library/LaunchAgents/com.foo.bar.plist")
        #expect(try await scan(fx, app(fx)).isEmpty)
    }
}
