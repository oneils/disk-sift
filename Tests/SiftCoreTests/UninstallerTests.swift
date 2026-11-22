import Foundation
import Testing

@testable import SiftCore

@Suite struct UninstallerTests {
    private struct Setup {
        let fx: Fixture
        let app: AppInfo
        let agent: Finding
        let daemon: Finding
        let cache: Finding
    }

    private func setup() throws -> Setup {
        let fx = try Fixture()
        let appURL = try fx.makeApp(bundleID: "com.foo.bar", name: "Bar")
        let agentURL = try fx.write("home/Library/LaunchAgents/com.foo.bar.plist")
        let daemonURL = try fx.write("Library/LaunchDaemons/com.foo.bar.daemon.plist")
        let cacheURL = try fx.write("home/Library/Caches/com.foo.bar/x")
        let app = AppInfo(url: appURL, bundleID: "com.foo.bar", name: "Bar", signing: .unsigned, nestedBundleIDs: [])
        return Setup(
            fx: fx, app: app,
            agent: Finding(
                url: agentURL, confidence: .high, sources: [.launchItem(label: "com.foo.bar", domain: .user)]),
            daemon: Finding(
                url: daemonURL, confidence: .high,
                sources: [.launchItem(label: "com.foo.bar.daemon", domain: .system)], requiresRoot: true),
            cache: Finding(url: cacheURL.deletingLastPathComponent(), confidence: .high, sources: [.libraryPath]))
    }

    private func uninstaller(
        _ s: Setup, runner: FakeCommandRunner, trasher: FakeTrasher
    ) -> Uninstaller {
        Uninstaller(
            remover: Remover(roots: RemovalRoots.make(s.fx.paths), trasher: trasher), runner: runner, uid: 501)
    }

    @Test func bootoutBeforeTrashAndSystemItemsSkipped() async throws {
        let s = try setup()
        let runner = FakeCommandRunner(fallback: CommandResult(status: 0))
        let trasher = FakeTrasher()
        let report = await uninstaller(s, runner: runner, trasher: trasher)
            .uninstall(s.app, leftovers: [s.agent, s.daemon, s.cache])
        #expect(runner.calls == [["/bin/launchctl", "bootout", "gui/501/com.foo.bar"]])
        #expect(trasher.trashed.first == s.app.url)
        #expect(report.removed.map(\.url) == [s.app.url, s.agent.url, s.daemon.url, s.cache.url])
        // the system-domain daemon gets no bootout (the fixture file is user-owned, so it is trashed anyway)
        #expect(!runner.calls.contains { $0.contains("gui/501/com.foo.bar.daemon") })
    }

    @Test func bootoutFailureIsNotFatal() async throws {
        let s = try setup()
        let runner = FakeCommandRunner(fallback: CommandResult(stderr: "no such service", status: 3))
        let trasher = FakeTrasher()
        let report = await uninstaller(s, runner: runner, trasher: trasher)
            .uninstall(s.app, leftovers: [s.agent])
        #expect(report.removed.map(\.url) == [s.app.url, s.agent.url])
        #expect(report.skipped.isEmpty)
    }

    @Test func appTrashFailureLeavesLeftoversAlone() async throws {
        let s = try setup()
        let runner = FakeCommandRunner(fallback: CommandResult(status: 0))
        let trasher = FakeTrasher()
        trasher.error = POSIXError(.EACCES)
        trasher.failing = [s.app.url.path]
        let report = await uninstaller(s, runner: runner, trasher: trasher)
            .uninstall(s.app, leftovers: [s.agent, s.cache])
        #expect(report.removed.isEmpty)
        #expect(report.skipped.map(\.url) == [s.app.url, s.agent.url, s.cache.url])
        #expect(
            report.skipped.dropFirst().allSatisfy { $0.reason == .appNotRemoved })
        #expect(trasher.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: s.cache.url.path))
        #expect(FileManager.default.fileExists(atPath: s.agent.url.path))
    }

    @Test func successReportsAppAndLeftovers() async throws {
        let s = try setup()
        let trasher = FakeTrasher()
        let report = await uninstaller(s, runner: FakeCommandRunner(fallback: CommandResult()), trasher: trasher)
            .uninstall(s.app, leftovers: [s.cache])
        #expect(report.removed.map(\.url) == [s.app.url, s.cache.url])
        #expect(trasher.trashed == [s.app.url, s.cache.url])
        #expect(!FileManager.default.fileExists(atPath: s.app.url.path))
    }
}
