import Foundation

public enum JunkProgress: Sendable {
    case categoryStarted(id: String)
    case findingSized(categoryID: String, finding: Finding)
    case categoryFinished(id: String)
}

/// Scans junk categories in parallel and reports progress as a stream.
public struct JunkScanner: Sendable {
    private let categories: [any JunkCategory]
    private let paths: SiftPaths

    public init(
        categories: [any JunkCategory] = [UserCachesCategory(), DevJunkCategory()], paths: SiftPaths = .live
    ) {
        self.categories = categories
        self.paths = paths
    }

    /// Ends when all categories finished; cancelling the consumer (or the stream) stops the scan.
    public func scan() -> AsyncStream<JunkProgress> {
        let categories = categories
        let paths = paths
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for category in categories {
                        group.addTask {
                            continuation.yield(.categoryStarted(id: category.id))
                            do {
                                for var finding in try await category.scan(paths: paths) {
                                    try Task.checkCancellation()
                                    let size = try await DirectorySizer.size(of: finding.url)
                                    finding.size = size.bytes
                                    finding.inaccessible = finding.inaccessible || size.inaccessible
                                    continuation.yield(.findingSized(categoryID: category.id, finding: finding))
                                }
                            } catch is CancellationError {
                                return
                            } catch {
                                Log.scan.error(
                                    "junk category failed: \(String(describing: error), privacy: .public)")
                            }
                            continuation.yield(.categoryFinished(id: category.id))
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
