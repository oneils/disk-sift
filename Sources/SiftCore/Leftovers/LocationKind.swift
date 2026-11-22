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
    /// Builds the lookup table on every call; use `LocationKindResolver` for many lookups.
    public static func of(_ directory: URL, paths: SiftPaths) -> LocationKind {
        LocationKindResolver(paths: paths).kind(of: directory)
    }

    /// Standardized, lowercased path of every scan directory with its kind.
    static func table(_ paths: SiftPaths) -> [String: LocationKind] {
        var table: [String: LocationKind] = [:]
        for (base, subdirs) in [
            (paths.library, ScanLocations.userLibrarySubdirs),
            (paths.systemLibrary, ScanLocations.systemLibrarySubdirs),
        ] {
            for subdir in subdirs {
                let key = base.appendingPathComponent(subdir).standardizedFileURL.path.lowercased()
                if table[key] == nil { table[key] = kind(ofSubdir: subdir) }
            }
        }
        return table
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

/// `LocationKind.of` with the lookup table built once: one dictionary lookup per directory instead of
/// building and standardizing every scan directory's URL (lists with thousands of rows call it per row).
public struct LocationKindResolver: Sendable {
    private let table: [String: LocationKind]

    public init(paths: SiftPaths) {
        table = LocationKind.table(paths)
    }

    public func kind(of directory: URL) -> LocationKind {
        table[directory.standardizedFileURL.path.lowercased()] ?? .other
    }
}
