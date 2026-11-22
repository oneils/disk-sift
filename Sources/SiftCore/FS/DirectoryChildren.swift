import Foundation

/// A direct child of a directory with its allocated size.
public struct DirectoryChild: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file
        case directory
        /// Listed as a link; never followed, its size is the link itself.
        case symlink
    }

    public var url: URL
    public var kind: Kind
    public var size: Int64
    /// Some of it could not be read (EPERM/EACCES), so `size` is partial.
    public var inaccessible: Bool

    public init(url: URL, kind: Kind, size: Int64, inaccessible: Bool = false) {
        self.url = url
        self.kind = kind
        self.size = size
        self.inaccessible = inaccessible
    }
}

public enum DirectoryChildren {
    /// Direct children (files and directories) sized concurrently with `DirectorySizer`, largest first
    /// (ties by name). A missing, non-directory or unreadable directory gives an empty list.
    /// Throws `CancellationError` when the surrounding task is cancelled.
    public static func list(of url: URL) async throws -> [DirectoryChild] {
        try Task.checkCancellation()
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
            let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return [] }

        let limit = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var result: [DirectoryChild] = []
        try await withThrowingTaskGroup(of: DirectoryChild?.self) { group in
            var iterator = names.makeIterator()
            func addNext(_ group: inout ThrowingTaskGroup<DirectoryChild?, any Error>) -> Bool {
                guard let name = iterator.next() else { return false }
                let child = url.appendingPathComponent(name)
                group.addTask { try await describe(child) }
                return true
            }
            var running = 0
            while running < limit, addNext(&group) { running += 1 }
            while let item = try await group.next() {
                if let item { result.append(item) }
                _ = addNext(&group)
            }
        }
        return result.sorted {
            $0.size != $1.size ? $0.size > $1.size : $0.url.lastPathComponent < $1.url.lastPathComponent
        }
    }

    private static func describe(_ url: URL) async throws -> DirectoryChild? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let kind: DirectoryChild.Kind
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .file
        }
        let size = try await DirectorySizer.size(of: url)
        return DirectoryChild(url: url, kind: kind, size: size.bytes, inaccessible: size.inaccessible)
    }
}
