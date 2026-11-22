import Foundation

/// Local iPhone/iPad backups made by Finder. Each backup can be the only copy of a device's data, so
/// nothing is preselected and removal goes to the Trash. Reading the folder needs Full Disk Access.
public struct IOSBackupsCategory: JunkCategory {
    public static let categoryID = "iosBackups"
    public let id = IOSBackupsCategory.categoryID
    public let title = "iPhone and iPad backups"
    public let policy = RemovalPolicy.trash
    /// Inside are thousands of hashed folders; nothing to inspect.
    public let expandable = false

    public init() {}

    public static func dir(_ paths: SiftPaths) -> URL {
        paths.library.appendingPathComponent("Application Support/MobileSync/Backup", isDirectory: true)
    }

    public func scan(paths: SiftPaths) async throws -> [Finding] {
        let dir = Self.dir(paths)
        var result: [Finding] = []
        for name in try JunkSupport.contents(of: dir) ?? [] {
            try Task.checkCancellation()
            let url = dir.appendingPathComponent(name, isDirectory: true)
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            if let finding = JunkSupport.finding(
                url, categoryID: id, policy: policy, paths: paths, displayName: Self.displayName(of: url))
            {
                result.append(finding)
            }
        }
        return result
    }

    public func checkedByDefault(_ finding: Finding, running: [RunningApp]) -> Bool { false }

    /// "Device Name — date" from the backup's Info.plist; nil when it is missing or unreadable.
    static func displayName(of backup: URL) -> String? {
        guard let data = try? Data(contentsOf: backup.appendingPathComponent("Info.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let device = plist["Device Name"] as? String, !device.isEmpty
        else { return nil }
        guard let date = plist["Last Backup Date"] as? Date else { return device }
        return "\(device) — \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}
