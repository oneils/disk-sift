import Foundation

/// What a leftover directory is for, so results can be grouped under readable names
/// ("Caches") instead of raw paths (`~/Library/Caches`).
public enum LocationKind: String, Sendable, CaseIterable {
    case applicationSupport
    case caches
    case preferences
    case containers
    case groupContainers
    case savedState
    case logs
    case webData
    case loginServices
    case applicationScripts
    case autosave
    case other

    /// Kind of a scan directory (a `FindingGroup` parent). Unknown directories are `.other`.
    public static func of(_ directory: URL, paths: SiftPaths) -> LocationKind {
        let path = directory.standardizedFileURL.path.lowercased()
        for (base, subdirs) in [
            (paths.library, ScanLocations.userLibrarySubdirs),
            (paths.systemLibrary, ScanLocations.systemLibrarySubdirs),
        ] {
            for subdir in subdirs
            where base.appendingPathComponent(subdir).standardizedFileURL.path.lowercased() == path {
                return kind(ofSubdir: subdir)
            }
        }
        return .other
    }

    /// True for directories under `/Library` (shared by all users of the Mac).
    public static func isSystem(_ directory: URL, paths: SiftPaths) -> Bool {
        let base = paths.systemLibrary.standardizedFileURL.path.lowercased() + "/"
        return directory.standardizedFileURL.path.lowercased().hasPrefix(base)
    }

    private static func kind(ofSubdir subdir: String) -> LocationKind {
        switch subdir {
        case "Application Support": .applicationSupport
        case "Caches": .caches
        case "Preferences", "Preferences/ByHost": .preferences
        case "Containers": .containers
        case "Group Containers": .groupContainers
        case "Saved Application State": .savedState
        case "Logs": .logs
        case "HTTPStorages", "WebKit", "Cookies": .webData
        case "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools": .loginServices
        case "Application Scripts": .applicationScripts
        case "Autosave Information": .autosave
        default: .other
        }
    }
}

extension SiftPaths {
    /// `path` with the home directory abbreviated to `~`.
    public func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = self.home.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
