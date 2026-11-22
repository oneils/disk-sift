import Foundation

/// The only places DiskSift may remove things from. Built from the same constants the scanners use,
/// so scanners and the remover cannot drift apart.
public struct RemovalRoots: Sendable {
    public let roots: [CanonicalPath]

    public init(roots: [CanonicalPath]) {
        self.roots = roots
    }

    public static func make(_ paths: SiftPaths) -> RemovalRoots {
        var urls = ScanLocations.leftoverDirs(paths)
        // parents of dev junk paths, so each junk path itself is removable
        urls += DevJunkCategory.paths(paths).map { $0.deletingLastPathComponent() }
        urls += [paths.applications, paths.userApplications]
        var seen: Set<String> = []
        var roots: [CanonicalPath] = []
        for url in urls {
            let root = canonicalRoot(url)
            if seen.insert(root.path.lowercased()).inserted { roots.append(root) }
        }
        return RemovalRoots(roots: roots)
    }

    /// Canonical path of `url` when it is strictly inside a root and is not a root itself
    /// (`~/Library/Caches` is never removable, even though `Preferences/ByHost` sits inside `Preferences`).
    public func allows(_ path: CanonicalPath) -> Bool {
        let lower = path.path.lowercased()
        if roots.contains(where: { $0.path.lowercased() == lower }) { return false }
        return roots.contains { path.isStrictlyInside($0) }
    }

    /// Resolves a root that may not exist yet: the nearest existing ancestor is `realpath`ed.
    private static func canonicalRoot(_ url: URL) -> CanonicalPath {
        if let resolved = try? CanonicalPath.of(url) { return resolved }
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                let joined = ([base == "/" ? "" : base] + tail).joined(separator: "/")
                return CanonicalPath(path: joined)
            }
        }
        return CanonicalPath(path: url.standardizedFileURL.path)
    }
}
