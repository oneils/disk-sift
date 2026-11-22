import Foundation

/// Which removal scope a junk category's findings go through.
public enum JunkRemovalScope: Sendable, Equatable {
    /// `RemovalRoots.make`: the Library scan dirs and dev cache parents.
    case library
    /// `RemovalRoots.largeFiles`: home minus the deny list, files only, Trash only.
    case largeFiles
}

/// Thrown by `JunkCategory.scan` when the category's directory exists but can't be listed
/// (typically missing Full Disk Access); shown as "No access", never as an empty category.
public enum JunkCategoryError: Error, Equatable {
    case unreadable
}

/// A group of junk locations offered for removal.
public protocol JunkCategory: Sendable {
    var id: String { get }
    var title: String { get }
    var policy: RemovalPolicy { get }
    /// Whether findings can be expanded into their children in the UI.
    var expandable: Bool { get }
    var removalScope: JunkRemovalScope { get }
    /// Existing candidates, not sized yet.
    func scan(paths: SiftPaths) async throws -> [Finding]
    func checkedByDefault(_ finding: Finding, running: [RunningApp]) -> Bool
}

extension JunkCategory {
    public var expandable: Bool { true }
    public var removalScope: JunkRemovalScope { .library }
}

enum JunkSupport {
    /// Unsized finding for an existing path, nil when it is missing. Removability is checked for the
    /// category's policy (trashing a directory needs different rights than deleting it).
    static func finding(
        _ url: URL, categoryID: String, policy: RemovalPolicy, paths: SiftPaths, displayName: String? = nil
    ) -> Finding? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Finding(
            url: url, confidence: .high, sources: [.junk(categoryID: categoryID)],
            requiresRoot: !Writability.canRemove(url, policy: policy), displayName: displayName)
    }

    /// Names in `dir`; nil when it doesn't exist; throws `unreadable` when it exists but can't be listed.
    static func contents(of dir: URL) throws -> [String]? {
        var st = stat()
        guard lstat(dir.path, &st) == 0 else { return nil }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        } catch {
            throw JunkCategoryError.unreadable
        }
    }
}
