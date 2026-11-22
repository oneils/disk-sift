import Foundation

/// Installer images and packages left in Downloads and on the Desktop. Moved to the Trash through the
/// large-files scope (files only), so neither folder ever becomes a permanent-deletion root.
public struct InstallersCategory: JunkCategory {
    public static let categoryID = "installers"
    public let id = InstallersCategory.categoryID
    public let title = "Installers"
    public let policy = RemovalPolicy.trash
    public let expandable = false
    public let removalScope = JunkRemovalScope.largeFiles

    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]
    /// Installers older than this are preselected; newer ones may still be needed.
    static let preselectAge: TimeInterval = 30 * 24 * 60 * 60

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public static func dirs(_ paths: SiftPaths) -> [URL] {
        ["Downloads", "Desktop"].map { paths.home.appendingPathComponent($0, isDirectory: true) }
    }

    /// Regular files with an installer extension directly in each folder (no recursion; bundle-style
    /// `.pkg` directories are skipped). An unreadable folder makes the whole category "No access".
    public func scan(paths: SiftPaths) async throws -> [Finding] {
        var result: [Finding] = []
        for dir in Self.dirs(paths) {
            try Task.checkCancellation()
            for name in try JunkSupport.contents(of: dir) ?? [] {
                guard Self.extensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                let url = dir.appendingPathComponent(name)
                var st = stat()
                guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                if let finding = JunkSupport.finding(url, categoryID: id, policy: policy, paths: paths) {
                    result.append(finding)
                }
            }
        }
        return result
    }

    public func checkedByDefault(_ finding: Finding, running: [RunningApp]) -> Bool {
        var st = stat()
        guard !finding.requiresRoot, lstat(finding.url.path, &st) == 0 else { return false }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        return now().timeIntervalSince(modified) > Self.preselectAge
    }
}
