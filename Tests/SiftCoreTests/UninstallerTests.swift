import Foundation
import Testing
import os

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

    @Test func uninstallProgressAndStoppingAfterApp() async throws {
        let s = try setup()
        let runner = FakeCommandRunner(fallback: CommandResult(status: 0))
        let trasher = FakeTrasher()
        let inst = uninstaller(s, runner: runner, trasher: trasher)
        let app = s.app
        let cache = s.cache
        let appURL = s.app.url
        let cachePath = s.cache.url.path

        let steps = OSAllocatedUnfairLock<[RemovalProgressState]>(initialState: [])

        let task = Task {
            await inst.uninstall(app, leftovers: [cache]) { state in
                steps.withLock { $0.append(state) }
                if state.completed == 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let report = await task.value

        #expect(trasher.trashed == [appURL])
        #expect(report.removed.map { $0.url } == [appURL])
        #expect(report.unprocessed.map { $0.url } == [cache.url])
        #expect(report.stopped)
        #expect(FileManager.default.fileExists(atPath: cachePath))
    }

    @Test func uninstallStoppingDuringLeftovers() async throws {
        let s = try setup()
        let runner = FakeCommandRunner(fallback: CommandResult(status: 0))
        let trasher = FakeTrasher()
        let inst = uninstaller(s, runner: runner, trasher: trasher)
        let app = s.app
        let agent = s.agent
        let cache = s.cache
        let appURL = s.app.url
        let agentURL = s.agent.url
        let cacheURL = s.cache.url

        let task = Task {
            await inst.uninstall(app, leftovers: [agent, cache]) { state in
                // state.completed == 1 means app finished, agent is current
                if state.completed == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let report = await task.value

        #expect(trasher.trashed == [appURL, agentURL])
        #expect(report.removed.map { $0.url } == [appURL, agentURL])
        #expect(report.unprocessed.map { $0.url } == [cacheURL])
        #expect(report.stopped)
    }

    @Test func uninstallStreamYieldsEvents() async throws {
        let s = try setup()
        let runner = FakeCommandRunner(fallback: CommandResult(status: 0))
        let trasher = FakeTrasher()
        let inst = uninstaller(s, runner: runner, trasher: trasher)

        var states: [RemovalProgressState] = []
        var finalReport: RemovalReport?
        for await event in inst.uninstallStream(s.app, leftovers: [s.cache]) {
            switch event {
            case .step(let st): states.append(st)
            case .completed(let rep): finalReport = rep
            }
        }

        #expect(states.count == 2)
        #expect(finalReport?.removed.count == 2)
    }
    @Test func cancelledBeforeStartDoesNotUnloadOrTrash() async throws {
        let s = try setup()
        let runner = FakeCommandRunner()
        let trasher = FakeTrasher()
        let inst = uninstaller(s, runner: runner, trasher: trasher)
        let task = Task { [app = s.app, leftovers = [s.agent, s.cache]] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await inst.uninstall(app, leftovers: leftovers)
        }
        let report = await task.value
        #expect(runner.calls.isEmpty)
        #expect(trasher.trashed.isEmpty)
        #expect(report.unprocessed.map(\.url) == [s.app.url, s.agent.url, s.cache.url])
        #expect(report.stopped)
    }

    @Test func stoppingDuringBootoutDoesNotUnloadNextAgentOrTrashApp() async throws {
        let s = try setup()
        let runner = CancellingRunner()
        let trasher = FakeTrasher()
        let inst = Uninstaller(remover: Remover(roots: .make(s.fx.paths), trasher: trasher), runner: runner)
        var second = s.cache
        second.sources = [.launchItem(label: "com.foo.second", domain: .user)]
        let leftovers = [s.agent, second]
        let task = Task { [app = s.app] in await inst.uninstall(app, leftovers: leftovers) }
        let report = await task.value
        #expect(runner.calls.withLock { $0 } == 1)
        #expect(trasher.trashed.isEmpty)
        #expect(report.stopped)
        #expect(report.unprocessed.map(\.url) == [s.app.url, s.agent.url, s.cache.url])
    }

    @Test func appSizeIncludedInProgressAndReport() async throws {
        let s = try setup()
        let size = try await DirectorySizer.size(of: s.app.url).bytes
        let steps = OSAllocatedUnfairLock<[RemovalProgressState]>(initialState: [])
        let report = await uninstaller(s, runner: FakeCommandRunner(), trasher: FakeTrasher())
            .uninstall(s.app, leftovers: [s.cache]) { state in
                steps.withLock { $0.append(state) }
            }
        #expect(report.removed.first?.size == size)
        #expect(steps.withLock { $0.last?.processedBytes } == size)
        #expect(steps.withLock { $0.last?.completed } == 1)
    }

}

private final class CancellingRunner: CommandRunner {
    let calls = OSAllocatedUnfairLock(initialState: 0)

    func run(_ exe: String, _ args: [String]) async throws -> CommandResult {
        calls.withLock { $0 += 1 }
        withUnsafeCurrentTask { $0?.cancel() }
        return CommandResult(status: 0)
    }
}
