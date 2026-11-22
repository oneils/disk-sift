import Foundation

/// Moves leftovers of removed apps to the Trash: unloads their user launch agents first, then trashes
/// every item through `Remover` (library removal roots, re-validated per item).
public struct OrphanRemover: Sendable {
    private let remover: Remover
    private let unloader: LaunchAgentUnloader

    public init(remover: Remover, runner: any CommandRunner, uid: UInt32 = UInt32(getuid())) {
        self.remover = remover
        unloader = LaunchAgentUnloader(runner: runner, uid: uid)
    }

    public func remove(
        _ findings: [Finding], onProgress: (@Sendable (RemovalProgressState) async -> Void)? = nil
    ) async -> RemovalReport {
        guard !Task.isCancelled, await unloader.unload(LaunchAgentUnloader.labels(in: findings)) else {
            return RemovalReport(unprocessed: findings, stopped: true)
        }
        return await remover.remove(findings, policy: .trash, onProgress: onProgress)
    }
}
