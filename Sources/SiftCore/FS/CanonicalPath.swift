import Foundation

/// A path with symlinks in the parent chain resolved. The last component is never followed,
/// so a symlink stays a link and removing it cannot touch its target.
public struct CanonicalPath: Hashable, Sendable {
    public let path: String

    public var url: URL { URL(fileURLWithPath: path) }

    init(path: String) {
        self.path = path
    }

    /// `realpath` of the parent directory plus the last component as given.
    /// Throws when the parent does not exist or cannot be resolved.
    public static func of(_ url: URL) throws -> CanonicalPath {
        let standardized = url.standardizedFileURL.path
        if standardized == "/" { return CanonicalPath(path: "/") }
        let parent = (standardized as NSString).deletingLastPathComponent
        let name = (standardized as NSString).lastPathComponent
        guard let resolved = realpath(parent.isEmpty ? "/" : parent, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        let resolvedParent = String(cString: resolved)
        let joined = resolvedParent == "/" ? "/\(name)" : "\(resolvedParent)/\(name)"
        return CanonicalPath(path: joined)
    }

    /// Path components, compared case-insensitively (default APFS).
    private var components: [String] {
        path.split(separator: "/").map { $0.lowercased() }
    }

    /// True when `self` is below `root`, component-wise. `root` itself is not inside `root`.
    public func isStrictlyInside(_ root: CanonicalPath) -> Bool {
        let mine = components
        let theirs = root.components
        guard mine.count > theirs.count else { return false }
        return Array(mine.prefix(theirs.count)) == theirs
    }
}
