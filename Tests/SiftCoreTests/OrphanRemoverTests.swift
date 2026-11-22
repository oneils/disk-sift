import Foundation
import Testing
import os

@testable import SiftCore

/// Records, for every trashed item, how many launchctl calls had happened before it.
private final class OrderCheckingTrasher: Trasher, @unchecked Sendable {
    let runner: FakeCommandRunner
    private let state = OSAllocatedUnfairLock(initialState: [Int]())
    init(runner: FakeCommandRunner) { self.runner = runner }
    var callsSeenAtTrash: [Int] { state.withLock { $0 } }
    func trash(_ url: URL) throws {
        let seen = runner.calls.count
        state.withLock { $0.append(seen) }
        try FileManager.default.removeItem(at: url)
    }
}

@Suite struct OrphanRemoverTests {
    private func setup() throws -> (Fixture, [Finding]) {
        let fx = try Fixture()
        let agent = try fx.write("home/Library/LaunchAgents/com.gone.app.agent.plist")
        let cache = try fx.mkdir("home/Library/Caches/com.gone.app")
        let prefs = try fx.write("home/Library/Preferences/com.gone.app.plist")
        let findings = [
            Finding(
                url: agent, size: 1, confidence: .medium,
                sources: [.orphan(groupID: "com.gone.app"), .launchItem(label: "com.gone.app.agent", domain: .user)]),
            Finding(url: cache, size: 2, confidence: .medium, sources: [.orphan(groupID: "com.gone.app")]),
            Finding(url: prefs, size: 3, confidence: .medium, sources: [.orphan(groupID: "com.gone.app")]),
        ]
        return (fx, findings)
    }

    @Test func unloadsAgentsBeforeTrashingAnything() async throws {
        let (fx, findings) = try setup()
        let runner = FakeCommandRunner(fallback: CommandResult(status: 0))
        let trasher = OrderCheckingTrasher(runner: runner)
        let remover = OrphanRemover(
            remover: Remover(roots: .make(fx.paths), trasher: trasher), runner: runner, uid: 501)
        let report = await remover.remove(findings + [findings[0]])
        #expect(runner.calls == [["/bin/launchctl", "bootout", "gui/501/com.gone.app.agent"]])
        #expect(trasher.callsSeenAtTrash.allSatisfy { $0 == 1 })
        #expect(report.removed.count == 3)
        #expect(!report.stopped)
    }

    @Test func failingBootoutDoesNotBlockRemoval() async throws {
        let (fx, findings) = try setup()
        let runner = FakeCommandRunner(fallback: CommandResult(status: 3))
        let trasher = FakeTrasher()
        let report = await OrphanRemover(
            remover: Remover(roots: .make(fx.paths), trasher: trasher), runner: runner, uid: 501
        ).remove(findings)
        #expect(report.removed.count == 3)
        #expect(trasher.trashed.count == 3)
    }

    @Test func onlyTrashIsUsed() async throws {
        let (fx, findings) = try setup()
        let trasher = FakeTrasher()
        _ = await OrphanRemover(
            remover: Remover(roots: .make(fx.paths), trasher: trasher), runner: FakeCommandRunner(), uid: 501
        ).remove(findings)
        // every item went through the trasher (permanent deletion never happens)
        #expect(Set(trasher.trashed.map(\.lastPathComponent)) == Set(findings.map(\.url.lastPathComponent)))
    }

    @Test func cancelledBeforeStartTouchesNothing() async throws {
        let (fx, findings) = try setup()
        let runner = FakeCommandRunner()
        let trasher = FakeTrasher()
        let remover = OrphanRemover(
            remover: Remover(roots: .make(fx.paths), trasher: trasher), runner: runner, uid: 501)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await remover.remove(findings)
        }
        let report = await task.value
        #expect(report.stopped)
        #expect(report.unprocessed.count == 3)
        #expect(runner.calls.isEmpty)
        #expect(trasher.trashed.isEmpty)
    }

    @Test func labelsAreUserOnlyAndUnique() {
        let a = Finding(
            url: URL(fileURLWithPath: "/a"), confidence: .high,
            sources: [.launchItem(label: "x", domain: .user), .launchItem(label: "sys", domain: .system)])
        let b = Finding(
            url: URL(fileURLWithPath: "/b"), confidence: .high, sources: [.launchItem(label: "x", domain: .user)])
        #expect(LaunchAgentUnloader.labels(in: [a, b]) == ["x"])
    }
}
