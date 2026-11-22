import Foundation

/// Unloads user-domain launch agents (`launchctl bootout gui/<uid>/<label>`) before their plists go to
/// the Trash, so launchd doesn't keep a dead job until logout. System-domain items are root-only and
/// never touched. Shared by `Uninstaller` and `OrphanRemover`.
struct LaunchAgentUnloader: Sendable {
    let runner: any CommandRunner
    let uid: UInt32

    /// User-domain labels of `findings`, each once, in a stable order.
    static func labels(in findings: [Finding]) -> [String] {
        var labels: [String] = []
        for finding in findings {
            for case .launchItem(let label, .user) in finding.sources.sorted(by: { "\($0)" < "\($1)" })
            where !labels.contains(label) {
                labels.append(label)
            }
        }
        return labels
    }

    /// Unloads each label; a failing `launchctl` is logged, not fatal. False when cancelled before the end.
    func unload(_ labels: [String]) async -> Bool {
        for label in labels {
            if Task.isCancelled { return false }
            do {
                let result = try await runner.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
                if result.status != 0 {
                    Log.removal.info("launchctl bootout \(label, privacy: .public) exited \(result.status)")
                }
            } catch {
                Log.removal.info("launchctl bootout \(label, privacy: .public) failed to run")
            }
        }
        return true
    }
}
