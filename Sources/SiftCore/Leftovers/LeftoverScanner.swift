import Foundation

/// Runs all leftover sources in parallel, merges their findings and sizes the result.
public struct LeftoverScanner: Sendable {
    private let sources: [any LeftoverSource]
    private let paths: SiftPaths

    public init(sources: [any LeftoverSource], paths: SiftPaths = .live) {
        self.sources = sources
        self.paths = paths
    }

    /// A failing source is logged and skipped; cancellation propagates.
    public func scan(_ app: AppInfo) async throws -> [Finding] {
        let paths = paths
        let all = try await withThrowingTaskGroup(of: [Finding].self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return try await source.findings(for: app, paths: paths)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Log.scan.error("leftover source failed: \(String(describing: error), privacy: .public)")
                        return []
                    }
                }
            }
            var collected: [Finding] = []
            for try await findings in group { collected += findings }
            return collected
        }
        try Task.checkCancellation()
        var merged = FindingMerger.merge(all)
        for index in merged.indices {
            try Task.checkCancellation()
            let size = try await DirectorySizer.size(of: merged[index].url)
            merged[index].size = size.bytes
            merged[index].inaccessible = merged[index].inaccessible || size.inaccessible
        }
        return merged
    }

    /// High confidence and removable by the current user.
    public static func defaultChecked(_ finding: Finding) -> Bool {
        finding.confidence == .high && !finding.requiresRoot
    }
}
