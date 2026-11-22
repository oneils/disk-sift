import Foundation
import SiftCore
import Testing
import os

@testable import DiskSift

private struct FakeValidator: AppValidating {
    var result: Result<AppInfo, ValidationError>
    func validate(_ url: URL) throws -> AppInfo { try result.get() }
}

private struct FakeScanner: LeftoverScanning {
    var findings: [Finding]
    func scan(_ app: AppInfo) async throws -> [Finding] { findings }
}

private final class FakeUninstaller: AppUninstalling {
    let calls = OSAllocatedUnfairLock<[[Finding]]>(initialState: [])
    let report: RemovalReport
    let pauseOnFirst: Bool
    init(report: RemovalReport = RemovalReport(), pauseOnFirst: Bool = false) {
        self.report = report
        self.pauseOnFirst = pauseOnFirst
    }
    func uninstall(
        _ app: AppInfo,
        leftovers: [Finding],
        onProgress: (@Sendable (RemovalProgressState) async -> Void)? = nil
    ) async -> RemovalReport {
        calls.withLock { $0.append(leftovers) }
        await onProgress?(
            RemovalProgressState(
                current: Finding(url: app.url, confidence: .high, sources: []), completed: 0,
                total: 1 + leftovers.count, processedBytes: 0))
        if pauseOnFirst {
            while !Task.isCancelled { await Task.yield() }
            if Task.isCancelled {
                return RemovalReport(unprocessed: leftovers, stopped: true)
            }
        }
        return report
    }
    func uninstall(_ app: AppInfo, leftovers: [Finding]) async -> RemovalReport {
        calls.withLock { $0.append(leftovers) }
        return report
    }
}

/// Reports `processes` as running until each is terminated (unless `ignoresTerminate`).
private final class FakeProcesses: RunningApps, ProcessTerminating {
    private let state: OSAllocatedUnfairLock<[RunningApp]>
    let ignoresTerminate: Bool
    let terminated = OSAllocatedUnfairLock<[Int32]>(initialState: [])
    let forced = OSAllocatedUnfairLock<[Int32]>(initialState: [])

    init(_ processes: [RunningApp], ignoresTerminate: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: processes)
        self.ignoresTerminate = ignoresTerminate
    }

    func running() -> [RunningApp] { state.withLock { $0 } }

    func terminate(pid: Int32) {
        terminated.withLock { $0.append(pid) }
        if !ignoresTerminate { state.withLock { $0.removeAll { $0.pid == pid } } }
    }

    func forceTerminate(pid: Int32) {
        forced.withLock { $0.append(pid) }
        state.withLock { $0.removeAll { $0.pid == pid } }
    }
}

@MainActor
@Suite private struct UninstallModelTests {
    let appURL = URL(fileURLWithPath: "/Applications/Foo.app")

    var info: AppInfo {
        AppInfo(
            url: appURL, bundleID: "com.foo.app", name: "Foo", signing: .unsigned,
            nestedBundleIDs: ["com.foo.helper"])
    }

    func finding(_ path: String, _ confidence: Confidence, size: Int64 = 10, root: Bool = false) -> Finding {
        Finding(
            url: URL(fileURLWithPath: path), size: size, confidence: confidence, sources: [.libraryPath],
            requiresRoot: root)
    }

    fileprivate func model(
        validate: Result<AppInfo, ValidationError>? = nil, findings: [Finding] = [],
        processes: FakeProcesses = FakeProcesses([]), uninstaller: FakeUninstaller = FakeUninstaller()
    ) -> UninstallModel {
        UninstallModel(
            validator: FakeValidator(result: validate ?? .success(info)),
            scanner: FakeScanner(findings: findings), uninstaller: uninstaller, runningApps: processes,
            terminator: processes, quitTimeout: .milliseconds(30), pollInterval: .milliseconds(10))
    }

    @Test func invalidDropShowsError() async {
        let m = model(validate: .failure(.notAnApp))
        await m.drop([URL(fileURLWithPath: "/tmp/x.txt")])
        #expect(m.phase == .idle)
        #expect(m.errorKey == ValidationError.notAnApp.messageKey)
    }

    @Test func notRemovableAppShowsAdminError() async {
        let m = model(validate: .failure(.notRemovable))
        await m.drop([appURL])
        #expect(m.phase == .idle)
        #expect(m.errorKey?.contains("administrator") == true)
    }

    @Test func runningHelperDetectedByNestedIDAndBundleURL() async {
        let helper = RunningApp(bundleID: "com.foo.helper", bundleURL: nil, pid: 2)
        let inside = RunningApp(
            bundleID: "other.id", bundleURL: appURL.appendingPathComponent("Contents/Helpers/H.app"), pid: 3)
        let unrelated = RunningApp(
            bundleID: "x", bundleURL: URL(fileURLWithPath: "/Applications/Foo.app.bak/X.app"), pid: 4)
        let m = model(processes: FakeProcesses([helper, inside, unrelated]))
        await m.drop([appURL])
        #expect(m.phase == .quitPrompt(running: [helper, inside]))
    }

    @Test func quitDeclinedResets() async {
        let main = RunningApp(bundleID: "com.foo.app", bundleURL: appURL, pid: 1)
        let processes = FakeProcesses([main])
        let m = model(processes: processes)
        await m.drop([appURL])
        m.declineQuit()
        #expect(m.phase == .idle)
        #expect(processes.terminated.withLock { $0 }.isEmpty)
    }

    @Test func quitTerminatesThenForces() async {
        let main = RunningApp(bundleID: "com.foo.app", bundleURL: appURL, pid: 1)
        let processes = FakeProcesses([main], ignoresTerminate: true)
        let m = model(processes: processes)
        await m.drop([appURL])
        await m.confirmQuit()
        #expect(processes.terminated.withLock { $0 } == [1])
        #expect(processes.forced.withLock { $0 } == [1])
        #expect(m.phase == .results)
    }

    @Test func gracefulQuitDoesNotForce() async {
        let main = RunningApp(bundleID: "com.foo.app", bundleURL: appURL, pid: 1)
        let processes = FakeProcesses([main])
        let m = model(processes: processes)
        await m.drop([appURL])
        await m.confirmQuit()
        #expect(processes.forced.withLock { $0 }.isEmpty)
        #expect(m.phase == .results)
    }

    @Test func scanShowsResultsWithDefaultChecks() async {
        let high = finding("/Users/u/Library/Caches/com.foo.app", .high, size: 100)
        let low = finding("/Users/u/Library/Caches/foo", .low, size: 5)
        let root = finding("/Library/LaunchDaemons/com.foo.plist", .high, size: 1, root: true)
        let m = model(findings: [high, low, root])
        await m.drop([appURL])
        #expect(m.phase == .results)
        #expect(m.groups.count == 2)
        #expect(m.isChecked(high))
        #expect(!m.isChecked(low))
        #expect(!m.isChecked(root))
        #expect(m.selectedTotal == 100)
        m.setChecked(low, true)
        m.setChecked(root, true)
        #expect(m.selectedTotal == 105)
        #expect(m.selectedFindings.count == 2)
    }

    @Test func trashPassesSelectionAndReportsAppNotRemoved() async {
        let high = finding("/Users/u/Library/Caches/com.foo.app", .high)
        let report = RemovalReport(skipped: [
            SkippedItem(url: appURL, reason: .permissionDenied),
            SkippedItem(url: high.url, reason: .appNotRemoved),
        ])
        let uninstaller = FakeUninstaller(report: report)
        let m = model(findings: [high], uninstaller: uninstaller)
        await m.drop([appURL])
        await m.trash()
        #expect(uninstaller.calls.withLock { $0 } == [[high]])
        #expect(m.phase == .report(report))
        m.reset()
        #expect(m.phase == .idle)
    }

    @Test(.timeLimit(.minutes(1))) func trashStopCancelsAndLeavesRemaining() async {
        let high = finding("/Users/u/Library/Caches/com.foo.app", .high)
        let uninstaller = FakeUninstaller(pauseOnFirst: true)
        let m = model(findings: [high], uninstaller: uninstaller)
        await m.drop([appURL])
        let task = Task { await m.trash() }
        while m.removalProgress == nil { await Task.yield() }
        #expect(m.phase == .removing)
        #expect(m.removalProgress?.completed == 0)
        #expect(!m.isStopping)
        m.reset()
        await m.drop([appURL])
        await m.trash()
        #expect(uninstaller.calls.withLock { $0.count } == 1)
        #expect(m.phase == .removing)
        m.stop()
        #expect(m.isStopping)
        await task.value
        #expect(!m.isStopping)
        guard case .report(let report) = m.phase else {
            Issue.record("expected report after stop")
            return
        }
        #expect(report.stopped)
        #expect(m.removalProgress == nil)
    }
}
