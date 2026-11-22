import Foundation

/// Every bundle ID that belongs to an installed app: the apps in the Applications folders and every
/// bundle nested anywhere inside them (helpers in `Frameworks`, XPC services, app extensions, system
/// extensions, Quick Look and Spotlight plugins). Used to keep live data out of the orphan scan.
public enum InstalledBundleIDs {
    /// How deep to look inside an app's `Contents` (Electron helpers sit about five levels down).
    static let maxDepth = 8
    static let bundleExtensions: Set<String> = [
        "app", "appex", "xpc", "framework", "bundle", "systemextension", "plugin", "qlgenerator", "mdimporter",
    ]

    /// Lowercased IDs of apps in `applications` and `userApplications` (top level plus one subfolder level,
    /// like `/Applications/Utilities`) and of all their nested bundles. Broken bundles are skipped.
    public static func collect(paths: SiftPaths) -> Set<String> {
        var ids: Set<String> = []
        for root in [paths.applications, paths.userApplications] {
            for app in apps(in: root) { collect(bundle: app, depth: 0, into: &ids) }
        }
        return ids
    }

    /// `.app` bundles in `dir` and in its plain subfolders. A symlinked app at this level is followed:
    /// counting it as installed is the conservative choice.
    static func apps(in dir: URL) -> [URL] {
        var result: [URL] = []
        for child in children(of: dir) {
            if child.pathExtension.lowercased() == "app" {
                result.append(child)
            } else if isRealDirectory(child) {
                result += children(of: child).filter { $0.pathExtension.lowercased() == "app" }
            }
        }
        return result
    }

    private static func collect(bundle: URL, depth: Int, into ids: inout Set<String>) {
        if let id = bundleID(of: bundle) { ids.insert(id.lowercased()) }
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        walk(isRealDirectory(contents) ? contents : bundle, depth: depth + 1, into: &ids)
    }

    /// Descends real directories only (never symlinks: frameworks link `Versions/Current` back into themselves).
    private static func walk(_ dir: URL, depth: Int, into ids: inout Set<String>) {
        guard depth <= maxDepth else { return }
        for child in children(of: dir) where isRealDirectory(child) {
            if bundleExtensions.contains(child.pathExtension.lowercased()) {
                collect(bundle: child, depth: depth, into: &ids)
            } else {
                walk(child, depth: depth + 1, into: &ids)
            }
        }
    }

    static func bundleID(of bundle: URL) -> String? {
        for plist in ["Contents/Info.plist", "Resources/Info.plist", "Info.plist"] {
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent(plist)),
                let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            if let id = dict["CFBundleIdentifier"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    private static func children(of dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            .map { dir.appendingPathComponent($0) }
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
