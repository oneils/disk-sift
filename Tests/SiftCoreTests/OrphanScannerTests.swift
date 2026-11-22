import Foundation
import Testing

@testable import SiftCore

@Suite struct OrphanCandidateTests {
    @Test(arguments: [
        ("com.foo.app.plist", "com.foo.app"),
        ("com.foo.app", "com.foo.app"),
        ("com.foo.app.savedState", "com.foo.app"),
        ("com.foo.app.binarycookies", "com.foo.app"),
        ("com.Foo.App", "com.foo.app"),
        ("org.some-vendor.my_tool", "org.some-vendor.my_tool"),
    ])
    func extractsBundleID(name: String, expected: String) {
        #expect(OrphanScanner.candidateID(fromName: name) == expected)
    }

    @Test func byHostSuffixesStripped() {
        #expect(
            OrphanScanner.candidateID(
                fromName: "com.foo.app.0A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D.plist", inByHost: true)
                == "com.foo.app")
        #expect(OrphanScanner.candidateID(fromName: "com.foo.app.001122AABBCC.plist", inByHost: true) == "com.foo.app")
        // outside ByHost the last component stays part of the ID
        #expect(OrphanScanner.candidateID(fromName: "com.foo.app.001122AABBCC.plist") == "com.foo.app.001122aabbcc")
    }

    @Test(arguments: [
        "ByHost", "byhost", "Foo", "com.foo", "com.foo.plist", "My App.app", "com..foo", "com.foo.bar baz",
        "com.foo.app!", "ru.фу.бар", ".com.foo.app",
    ])
    func rejectsNamesThatAreNotBundleIDs(name: String) {
        #expect(OrphanScanner.candidateID(fromName: name) == nil)
    }

    @Test(arguments: [
        "com.apple.Safari.plist", "COM.APPLE.finder", "ABCDE12345.com.foo.shared.plist", "UBF8T346G9.Office",
        "com.microsoft.office.plist", "com.microsoft.autoupdate2.plist", "com.Adobe.Acrobat.Pro", "org.python.python",
        "com.google.Keystone.Agent.plist",
    ])
    func rejectsAppleTeamAndExcludedNames(name: String) {
        #expect(OrphanScanner.candidateID(fromName: name) == nil)
    }

    @Test func excludedPrefixesMatchWholeComponents() {
        // "org.pythonic..." is not "org.python"
        #expect(OrphanScanner.candidateID(fromName: "org.pythonista.app") == "org.pythonista.app")
        #expect(OrphanScanner.candidateID(fromName: "com.adobeish.tool") == "com.adobeish.tool")
    }
}

@Suite struct OrphanScannerTests {
    private func app(_ fx: Fixture, _ relative: String, id: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
        try fx.write("\(relative)/Contents/Info.plist", data: data)
    }

    private func agent(_ fx: Fixture, _ name: String, label: String, program: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "Program": program], format: .xml, options: 0)
        try fx.write("home/Library/LaunchAgents/\(name)", data: data)
    }

    private func scan(
        _ fx: Fixture, known: Set<String> = [], running: [String] = [], fda: Bool = true
    ) async throws -> [OrphanGroup] {
        try await OrphanScanner(
            paths: fx.paths, installed: FakeInstalledApps(knownOutsideTrash: known),
            runningApps: FakeRunningApps(apps: running.map { RunningApp(bundleID: $0, bundleURL: nil, pid: 1) }),
            hasFullDiskAccess: { _ in fda }
        ).scan()
    }

    private func names(_ groups: [OrphanGroup], _ fx: Fixture) -> [String: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: groups.map { group in
                (
                    group.id,
                    Set(
                        group.findings.map {
                            $0.url.path.replacingOccurrences(of: fx.paths.library.path + "/", with: "")
                        })
                )
            })
    }

    @Test func leftoversOfAGoneAppAreGroupedTogether() async throws {
        let fx = try Fixture()
        try fx.write("home/Library/Application Support/com.gone.app/data.db", "x")
        try fx.write("home/Library/Caches/com.Gone.App/c", "x")
        try fx.write("home/Library/Preferences/com.gone.app.plist")
        try fx.write("home/Library/Preferences/ByHost/com.gone.app.0A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D.plist")
        try fx.write("home/Library/Saved Application State/com.gone.app.savedState/s")
        try fx.write("home/Library/Caches/com.gone.app.helper/h", "x")
        let groups = try await scan(fx)
        #expect(groups.count == 1)
        #expect(
            names(groups, fx)["com.gone.app"] == [
                "Application Support/com.gone.app", "Caches/com.Gone.App", "Preferences/com.gone.app.plist",
                "Preferences/ByHost/com.gone.app.0A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D.plist",
                "Saved Application State/com.gone.app.savedState", "Caches/com.gone.app.helper",
            ])
        let finding = try #require(groups.first?.findings.first)
        #expect(finding.evidence == [.appNotInstalled])
        #expect(finding.sources.contains(.orphan(groupID: "com.gone.app")))
        #expect(!finding.requiresRoot)
        #expect(groups[0].totalSize > 0)
    }

    @Test func dataOfInstalledAppsIsNeverReported() async throws {
        let fx = try Fixture()
        try app(fx, "Applications/Foo.app", id: "com.foo.app")
        try app(fx, "Applications/Foo.app/Contents/PlugIns/Share.appex", id: "io.vendor.share")
        try app(fx, "Applications/Pro.app", id: "com.bar.app.pro")
        for name in [
            "com.foo.app", "com.foo.app.helper", "io.vendor.share", "com.bar.app", "com.known.elsewhere",
            "com.running.tool",
        ] {
            try fx.write("home/Library/Caches/\(name)/c", "x")
        }
        try fx.write("home/Library/Containers/io.vendor.share/Data/x", "x")
        let groups = try await scan(fx, known: ["com.known.elsewhere"], running: ["com.Running.Tool"])
        #expect(groups.isEmpty)
    }

    @Test func appSittingInTheTrashDoesNotHideItsLeftovers() async throws {
        let fx = try Fixture()
        // Launch Services still knows it, but only in the Trash: the fake reports "not known outside the Trash"
        try app(fx, "home/.Trash/Gone.app", id: "com.gone.app")
        try fx.write("home/Library/Caches/com.gone.app/c", "x")
        #expect(try await scan(fx).map(\.id) == ["com.gone.app"])
    }

    @Test func liveAgentLabelProtectsItsData() async throws {
        let fx = try Fixture()
        let tool = try fx.write("home/Library/Application Support/com.tool.daemon/bin/daemon", "x")
        try agent(fx, "com.tool.daemon.plist", label: "com.tool.daemon", program: tool.path)
        #expect(try await scan(fx).isEmpty)
    }

    @Test func systemLibraryGroupContainersAndContainersWithoutFDA() async throws {
        let fx = try Fixture()
        try fx.write("Library/Caches/com.gone.app/c", "x")
        try fx.write("home/Library/Group Containers/group.com.gone.app/x", "x")
        try fx.write("home/Library/Containers/com.gone.sandboxed/Data/x", "x")
        #expect(try await scan(fx, fda: false).isEmpty)
        #expect(try await scan(fx, fda: true).map(\.id) == ["com.gone.sandboxed"])
    }

    @Test func agentWithMissingProgramInApplications() async throws {
        let fx = try Fixture()
        try agent(
            fx, "com.gone.app.agent.plist", label: "com.gone.app.agent",
            program: fx.paths.applications.path + "/Gone.app/Contents/MacOS/agent")
        try fx.write("home/Library/Caches/com.gone.app/c", "x")
        let groups = try await scan(fx)
        #expect(groups.map(\.id) == ["com.gone.app"])
        let agentFinding = try #require(groups[0].findings.first { $0.url.pathExtension == "plist" })
        #expect(agentFinding.evidence == [.launchProgramMissing])
        #expect(agentFinding.sources.contains(.launchItem(label: "com.gone.app.agent", domain: .user)))
    }

    @Test func missingProgramMatchedThroughASymlinkedRoot() async throws {
        let fx = try Fixture()
        // the plist names the program through a symlink to the Applications folder
        try fx.symlink("tmp/apps-link", to: fx.paths.applications.path)
        try agent(
            fx, "a.plist", label: "com.gone.linked", program: fx.url("tmp/apps-link/Gone.app/Contents/MacOS/a").path)
        #expect(try await scan(fx).map(\.id) == ["com.gone.linked"])
    }

    @Test func agentsThatAreNotOrphans() async throws {
        let fx = try Fixture()
        try app(fx, "Applications/Foo.app", id: "com.foo.app")
        let existing = try fx.write("Applications/Foo.app/Contents/MacOS/agent", "x")
        try agent(fx, "live.plist", label: "com.live.agent", program: existing.path)
        try agent(fx, "outside.plist", label: "com.outside.agent", program: fx.url("tmp/gone/agent").path)
        // renamed binary inside a still-installed app: label belongs to the installed app
        try agent(
            fx, "renamed.plist", label: "com.foo.app.updater",
            program: fx.paths.applications.path + "/Foo.app/Contents/MacOS/old-updater")
        try fx.write("home/Library/LaunchAgents/broken.plist", "not a plist")
        #expect(try await scan(fx).isEmpty)
    }

    @Test func everyFindingIsRemovableUnderLibraryRoots() async throws {
        let fx = try Fixture()
        try fx.write("home/Library/Caches/com.gone.app/c", "x")
        try fx.write("home/Library/Preferences/com.gone.app.plist")
        try fx.write("home/Library/HTTPStorages/com.gone.app/x", "x")
        let roots = RemovalRoots.make(fx.paths)
        let findings = try await scan(fx).flatMap(\.findings)
        #expect(findings.count == 3)
        for finding in findings { #expect(roots.allows(try CanonicalPath.of(finding.url))) }
    }

    @Test func cancellationStopsTheScan() async throws {
        let fx = try Fixture()
        for i in 0..<50 { try fx.write("home/Library/Caches/com.gone.app\(i).x/c", "x") }
        let scanner = OrphanScanner(
            paths: fx.paths, installed: FakeInstalledApps(), runningApps: FakeRunningApps(),
            hasFullDiskAccess: { _ in true })
        let task = Task { try await scanner.scan() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
