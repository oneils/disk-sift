import Foundation

/// The only places DiskSift may remove things from. Built from the same constants the scanners use,
/// so scanners and the remover cannot drift apart.
///
/// Three scopes exist: `.library` (uninstall and junk: inside the scanned Library folders, the
/// Applications folders and dev cache parents), `.largeFiles` (the home folder minus a deny list,
/// regular files only, Trash only) and `.spaceLens` (the same deny list, files and folders, Trash only).
/// The rules of a scope travel with it, so a `Remover` built on it enforces them without extra arguments.
public struct RemovalRoots: Sendable {
    public enum Kind: Sendable, Equatable {
        case library
        case largeFiles(LargeFilesScope)
        case spaceLens(LargeFilesScope)
    }

    public let roots: [CanonicalPath]
    public let kind: Kind

    public init(roots: [CanonicalPath]) {
        self.roots = roots
        kind = .library
    }

    private init(home: CanonicalPath, kind: Kind) {
        roots = [home]
        self.kind = kind
    }

    /// Strictly inside the home folder, outside the large-files deny list, on the home volume.
    public static func largeFiles(_ paths: SiftPaths) -> RemovalRoots {
        let scope = LargeFilesScope(paths: paths)
        return RemovalRoots(home: scope.home, kind: .largeFiles(scope))
    }

    /// Space Lens: the large-files deny list, but whole folders may go to the Trash too
    /// (`node_modules`, old projects). Never `~/Library`, `~/.Trash`, `~/Applications`, inside a package
    /// or `.git`, or another volume.
    public static func spaceLens(_ paths: SiftPaths) -> RemovalRoots {
        let scope = LargeFilesScope(paths: paths)
        return RemovalRoots(home: scope.home, kind: .spaceLens(scope))
    }

    /// Only regular files may be removed (no directories, no symlinks).
    public var filesOnly: Bool {
        if case .largeFiles = kind { return true }
        return false
    }

    /// Items may only be moved to the Trash, never deleted permanently.
    public var trashOnly: Bool { kind != .library }

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
        switch kind {
        case .largeFiles(let scope), .spaceLens(let scope): return !scope.isDenied(path)
        case .library: break
        }
        let lower = path.path.lowercased()
        if roots.contains(where: { $0.path.lowercased() == lower }) { return false }
        return roots.contains { path.isStrictlyInside($0) }
    }

    /// Resolves a root that may not exist yet: the nearest existing ancestor is `realpath`ed.
    static func canonicalRoot(_ url: URL) -> CanonicalPath {
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
