import Foundation

/// Uninstalls an app: unload its user launch agents, trash the app, then trash the checked leftovers.
public struct Uninstaller: Sendable {
    private let remover: Remover
    private let runner: any CommandRunner
    private let uid: UInt32

    public init(remover: Remover, runner: any CommandRunner, uid: UInt32 = UInt32(getuid())) {
        self.remover = remover
        self.runner = runner
        self.uid = uid
    }

    public func uninstall(_ app: AppInfo, leftovers: [Finding]) async -> RemovalReport {
        await uninstall(app, leftovers: leftovers, onProgress: nil)
    }

    public func uninstall(
        _ app: AppInfo,
        leftovers: [Finding],
        onProgress: (@Sendable (RemovalProgressState) async -> Void)? = nil
    ) async -> RemovalReport {
        let total = 1 + leftovers.count
        var appFinding = Finding(url: app.url, confidence: .high, sources: [])
        if Task.isCancelled {
            return RemovalReport(unprocessed: [appFinding] + leftovers, stopped: true)
        }
        // Include the bundle in processed sizes, not just its leftovers.
        appFinding.size = try? await DirectorySizer.size(of: app.url).bytes

        // 1. unload user-domain launch agents; system-domain items are root-only and never touched
        let unloader = LaunchAgentUnloader(runner: runner, uid: uid)
        guard await unloader.unload(LaunchAgentUnloader.labels(in: leftovers)) else {
            return RemovalReport(unprocessed: [appFinding] + leftovers, stopped: true)
        }

        if Task.isCancelled {
            return RemovalReport(unprocessed: [appFinding] + leftovers, stopped: true)
        }

        // 2. the app itself; on failure leave everything else alone
        let appReport = await remover.remove([appFinding], policy: .trash) { state in
            await onProgress?(
                RemovalProgressState(
                    current: state.current,
                    completed: 0,
                    total: total,
                    processedBytes: 0
                ))
        }

        if !appReport.skipped.isEmpty {
            var report = appReport
            report.skipped += leftovers.map { SkippedItem(url: $0.url, reason: .appNotRemoved) }
            return report
        }

        if appReport.removed.isEmpty {
            return RemovalReport(
                skipped: appReport.skipped,
                unprocessed: [appFinding] + leftovers,
                stopped: true
            )
        }

        let finalRemoved = appReport.removed
        let finalSkipped = appReport.skipped
        let baseBytes = appReport.removed.first?.size ?? 0

        if Task.isCancelled || appReport.stopped {
            return RemovalReport(
                removed: finalRemoved,
                skipped: finalSkipped,
                unprocessed: leftovers,
                stopped: !leftovers.isEmpty
            )
        }

        // 3. leftovers
        let leftoverReport = await remover.remove(leftovers, policy: .trash) { state in
            await onProgress?(
                RemovalProgressState(
                    current: state.current,
                    completed: 1 + state.completed,
                    total: total,
                    processedBytes: baseBytes + state.processedBytes
                ))
        }

        return RemovalReport(
            removed: finalRemoved + leftoverReport.removed,
            skipped: finalSkipped + leftoverReport.skipped,
            unprocessed: leftoverReport.unprocessed,
            stopped: leftoverReport.stopped
        )
    }

    public func uninstallStream(
        _ app: AppInfo,
        leftovers: [Finding]
    ) -> AsyncStream<RemovalProgress> {
        AsyncStream { continuation in
            let task = Task {
                let report = await self.uninstall(app, leftovers: leftovers) { state in
                    continuation.yield(.step(state))
                }
                continuation.yield(.completed(report: report))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
