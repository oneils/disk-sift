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
        // 1. unload user-domain launch agents; system-domain items are root-only and never touched
        var labels: [String] = []
        for finding in leftovers {
            for case .launchItem(let label, .user) in finding.sources.sorted(by: { "\($0)" < "\($1)" })
            where !labels.contains(label) {
                labels.append(label)
            }
        }
        for label in labels {
            do {
                let result = try await runner.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
                if result.status != 0 {
                    Log.removal.info("launchctl bootout \(label, privacy: .public) exited \(result.status)")
                }
            } catch {
                Log.removal.info("launchctl bootout \(label, privacy: .public) failed to run")
            }
        }

        // 2. the app itself; on failure leave everything else alone
        let appFinding = Finding(url: app.url, confidence: .high, sources: [])
        let appReport = remover.remove([appFinding], policy: .trash)
        if !appReport.skipped.isEmpty {
            var report = appReport
            report.skipped += leftovers.map { SkippedItem(url: $0.url, reason: .appNotRemoved) }
            return report
        }

        // 3. leftovers
        let leftoverReport = remover.remove(leftovers, policy: .trash)
        return RemovalReport(
            removed: appReport.removed + leftoverReport.removed,
            skipped: leftoverReport.skipped)
    }
}
