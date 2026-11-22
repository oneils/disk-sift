import Foundation

/// A regular file found by `LargeFileScanner`.
public struct LargeFile: Identifiable, Hashable, Sendable {
    public var url: URL
    /// Allocated bytes on disk (the same measure as `DirectorySizer`).
    public var size: Int64
    public var modified: Date?

    public var id: String { url.path }

    public init(url: URL, size: Int64, modified: Date?) {
        self.url = url
        self.size = size
        self.modified = modified
    }

    /// As a removal candidate for `Remover`.
    public var finding: Finding {
        Finding(url: url, size: size, confidence: .high, sources: [.largeFile])
    }
}

public enum LargeFileProgress: Sendable, Equatable {
    case found(LargeFile)
    /// Entries looked at so far and the directory being walked (throttled).
    case progress(scanned: Int, directory: URL)
    /// A directory that could not be read; its contents are not in the results.
    case unreadable(URL)
    /// The walk completed. Missing when the scan was cancelled.
    case finished
}

/// Walks the home folder for regular files of at least `minimumSize`, skipping what
/// `LargeFilesScope` denies (Library, Trash, Applications, packages, `.git`, other volumes).
/// Symlinks are never followed and hard links are reported once.
public struct LargeFileScanner: Sendable {
    /// Decimal, like the sizes the app displays (`ByteCountFormatter`, file style).
    public static let defaultMinimumSize: Int64 = 100_000_000

    private let scope: LargeFilesScope
    private let minimumSize: Int64
    private let progressEvery: Int

    public init(paths: SiftPaths, minimumSize: Int64 = defaultMinimumSize, progressEvery: Int = 500) {
        scope = LargeFilesScope(paths: paths)
        self.minimumSize = minimumSize
        self.progressEvery = max(1, progressEvery)
    }

    /// Ends with `.finished` after a complete walk; cancelling the consumer stops the walk.
    public func scan() -> AsyncStream<LargeFileProgress> {
        let scope = scope
        let minimumSize = minimumSize
        let progressEvery = progressEvery
        return AsyncStream { continuation in
            let task = Task.detached {
                let completed = Self.walk(
                    scope: scope, minimumSize: minimumSize, progressEvery: progressEvery
                ) { continuation.yield($0) }
                if completed { continuation.yield(.finished) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey, .contentModificationDateKey,
    ]

    /// Returns false when cancelled before the end.
    private static func walk(
        scope: LargeFilesScope, minimumSize: Int64, progressEvery: Int, emit: @escaping (LargeFileProgress) -> Void
    ) -> Bool {
        let home = scope.home.url
        guard
            let enumerator = FileManager.default.enumerator(
                at: home, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                errorHandler: { url, _ in
                    emit(.unreadable(url))
                    return true
                })
        else {
            emit(.unreadable(home))
            return true
        }
        var scanned = 0
        var seenInodes: Set<UInt64> = []
        var directory = home
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return false }
            scanned += 1
            if scanned % progressEvery == 0 { emit(.progress(scanned: scanned, directory: directory)) }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                var st = stat()
                let device = lstat(url.path, &st) == 0 ? st.st_dev : nil
                if scope.shouldSkipDirectory(url, isPackage: values.isPackage == true, device: device) {
                    enumerator.skipDescendants()
                } else {
                    directory = url
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            guard size >= minimumSize else { continue }
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            if st.st_nlink > 1, !seenInodes.insert(UInt64(st.st_ino)).inserted { continue }
            emit(.found(LargeFile(url: url, size: size, modified: values.contentModificationDate)))
        }
        return !Task.isCancelled
    }
}
