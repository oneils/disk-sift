import Foundation

/// Attachments Mail saved when they were opened; Mail downloads them again on demand.
/// Deleted permanently. Reading the container needs Full Disk Access.
public struct MailDownloadsCategory: JunkCategory {
    public static let categoryID = "mailDownloads"
    public static let mailBundleID = "com.apple.mail"
    public let id = MailDownloadsCategory.categoryID
    public let title = "Mail downloads"
    public let policy = RemovalPolicy.delete

    public init() {}

    public static func dir(_ paths: SiftPaths) -> URL {
        paths.library.appendingPathComponent(
            "Containers/com.apple.mail/Data/Library/Mail Downloads", isDirectory: true)
    }

    public func scan(paths: SiftPaths) async throws -> [Finding] {
        let dir = Self.dir(paths)
        var result: [Finding] = []
        for name in try JunkSupport.contents(of: dir) ?? [] {
            try Task.checkCancellation()
            if let finding = JunkSupport.finding(
                dir.appendingPathComponent(name), categoryID: id, policy: policy, paths: paths)
            {
                result.append(finding)
            }
        }
        return result
    }

    /// Selected unless Mail is running (it may have an attachment open).
    public func checkedByDefault(_ finding: Finding, running: [RunningApp]) -> Bool {
        !finding.requiresRoot && !running.contains { $0.bundleID == Self.mailBundleID }
    }
}
