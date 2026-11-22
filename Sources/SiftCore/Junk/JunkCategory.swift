import Foundation

/// A group of junk locations offered for permanent deletion.
public protocol JunkCategory: Sendable {
    var id: String { get }
    var title: String { get }
    var policy: RemovalPolicy { get }
    /// Existing candidates, not sized yet.
    func scan(paths: SiftPaths) async throws -> [Finding]
    func checkedByDefault(_ finding: Finding, running: [RunningApp]) -> Bool
}

enum JunkSupport {
    /// Unsized finding for an existing path, nil when it is missing.
    static func finding(_ url: URL, categoryID: String, paths: SiftPaths) -> Finding? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Finding(
            url: url, confidence: .high, sources: [.junk(categoryID: categoryID)],
            requiresRoot: !Writability.canRemove(url, policy: .delete))
    }
}
