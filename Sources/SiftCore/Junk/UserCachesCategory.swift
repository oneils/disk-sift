import Foundation

/// Children of `~/Library/Caches` and `~/Library/Logs`, minus what `DevJunkCategory` owns.
public struct UserCachesCategory: JunkCategory {
    public static let categoryID = "userCaches"
    public let id = UserCachesCategory.categoryID
    public let title = "User caches and logs"
    public let policy = RemovalPolicy.delete

    public init() {}

    public static func dirs(_ paths: SiftPaths) -> [URL] {
        [
            paths.library.appendingPathComponent("Caches", isDirectory: true),
            paths.library.appendingPathComponent("Logs", isDirectory: true),
        ]
    }

    public func scan(paths: SiftPaths) async throws -> [Finding] {
        let owned = Set(DevJunkCategory.paths(paths).map { $0.standardizedFileURL.path.lowercased() })
        var result: [Finding] = []
        for dir in Self.dirs(paths) {
            try Task.checkCancellation()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names.sorted() {
                let url = dir.appendingPathComponent(name)
                if owned.contains(url.standardizedFileURL.path.lowercased()) { continue }
                if let finding = JunkSupport.finding(url, categoryID: id, paths: paths) {
                    result.append(finding)
                }
            }
        }
        return result
    }

    /// User caches and logs belong to many different apps, so nothing is preselected:
    /// the user picks what to delete.
    public func checkedByDefault(_ finding: Finding, running: [RunningApp]) -> Bool {
        false
    }
}
