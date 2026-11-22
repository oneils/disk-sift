import Foundation

/// The directories scanned for leftovers. Single source of truth: `RemovalRoots` is built from these too.
public enum ScanLocations {
    /// Subdirectories of `~/Library`.
    static let userLibrarySubdirs = [
        "Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers",
        "Saved Application State", "Logs", "HTTPStorages", "WebKit", "Cookies", "LaunchAgents",
        "Application Scripts", "Autosave Information",
    ]

    /// Subdirectories of `/Library`.
    static let systemLibrarySubdirs = [
        "Application Support", "Caches", "Preferences", "Logs", "LaunchAgents", "LaunchDaemons",
        "PrivilegedHelperTools",
    ]

    /// Directories whose direct children are checked for leftovers.
    public static func leftoverDirs(_ paths: SiftPaths) -> [URL] {
        userLibrarySubdirs.map { paths.library.appendingPathComponent($0, isDirectory: true) }
            + systemLibrarySubdirs.map { paths.systemLibrary.appendingPathComponent($0, isDirectory: true) }
    }

    /// `~/Library/Containers` and `~/Library/Group Containers`: reading them needs Full Disk Access.
    static func protectedDirs(_ paths: SiftPaths) -> [URL] {
        ["Containers", "Group Containers"].map { paths.library.appendingPathComponent($0, isDirectory: true) }
    }

    static func groupContainersDir(_ paths: SiftPaths) -> URL {
        paths.library.appendingPathComponent("Group Containers", isDirectory: true)
    }

    /// Launch item directories are handled by `LaunchItemsSource`.
    static func launchDirs(_ paths: SiftPaths) -> [URL] {
        [
            paths.library.appendingPathComponent("LaunchAgents", isDirectory: true),
            paths.systemLibrary.appendingPathComponent("LaunchAgents", isDirectory: true),
            paths.systemLibrary.appendingPathComponent("LaunchDaemons", isDirectory: true),
        ]
    }
}
