import Foundation
import Testing

@testable import SiftCore

@Suite struct LaunchItemsSourceTests {
    private func plist(_ fx: Fixture, _ relative: String, _ dict: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try fx.write(relative, data: data)
    }

    private func app(_ fx: Fixture) -> AppInfo {
        AppInfo(
            url: fx.paths.applications.appendingPathComponent("Bar.app"), bundleID: "com.foo.bar", name: "Bar",
            signing: .unsigned, nestedBundleIDs: ["com.foo.bar.helper"])
    }

    @Test func labelMatchesBundleAndNestedID() async throws {
        let fx = try Fixture()
        try plist(fx, "home/Library/LaunchAgents/a.plist", ["Label": "com.foo.bar"])
        try plist(fx, "home/Library/LaunchAgents/b.plist", ["Label": "com.foo.bar.helper"])
        try plist(fx, "home/Library/LaunchAgents/c.plist", ["Label": "com.foo.bar.updater"])
        let found = try await LaunchItemsSource().findings(for: app(fx), paths: fx.paths)
        #expect(found.count == 3)
        #expect(found.allSatisfy { $0.confidence == .high && !$0.requiresRoot })
        #expect(found.first?.sources == [.launchItem(label: "com.foo.bar", domain: .user)])
        #expect(found.allSatisfy { $0.evidence == [.launchLabel] })
    }

    @Test func programInsideAppMatches() async throws {
        let fx = try Fixture()
        let exe = fx.paths.applications.path + "/Bar.app/Contents/MacOS/agent"
        try plist(fx, "home/Library/LaunchAgents/x.plist", ["Label": "unrelated.name", "Program": exe])
        try plist(fx, "home/Library/LaunchAgents/y.plist", ["Label": "other.name", "ProgramArguments": [exe, "-v"]])
        let found = try await LaunchItemsSource().findings(for: app(fx), paths: fx.paths)
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.evidence == [.launchProgramInApp] })
    }

    @Test func privilegedHelperMatchesAndSystemIsRootOnly() async throws {
        let fx = try Fixture()
        let helper = fx.paths.systemLibrary.path + "/PrivilegedHelperTools/com.foo.bar.helper"
        try plist(fx, "Library/LaunchDaemons/d.plist", ["Label": "x.y", "ProgramArguments": [helper]])
        try plist(fx, "Library/LaunchAgents/e.plist", ["Label": "com.foo.bar.agent"])
        let found = try await LaunchItemsSource().findings(for: app(fx), paths: fx.paths)
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.requiresRoot })
        #expect(
            found.allSatisfy { f in
                if case .launchItem(_, let domain) = f.sources.first { return domain == .system }
                return false
            })
    }

    @Test func unrelatedAndMalformedAreSkipped() async throws {
        let fx = try Fixture()
        try plist(fx, "home/Library/LaunchAgents/u.plist", ["Label": "com.foo.barbaz", "Program": "/usr/bin/true"])
        try plist(fx, "home/Library/LaunchAgents/v.plist", ["Label": "com.foo.bar"])
        try fx.write("home/Library/LaunchAgents/bad.plist", "not a plist")
        let found = try await LaunchItemsSource().findings(for: app(fx), paths: fx.paths)
        #expect(found.count == 1)
        #expect(found.first?.url.lastPathComponent == "v.plist")
    }
}
