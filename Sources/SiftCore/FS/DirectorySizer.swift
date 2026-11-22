import Foundation

/// Allocated size of a path plus whether parts of it could not be read.
public struct SizeResult: Sendable, Equatable {
    public var bytes: Int64
    public var inaccessible: Bool

    public init(bytes: Int64, inaccessible: Bool = false) {
        self.bytes = bytes
        self.inaccessible = inaccessible
    }
}

/// Computes allocated sizes (`st_blocks * 512`, the same measure as `du`).
/// Symlinks are never followed and hard links are counted once per call.
public enum DirectorySizer {
    /// Missing paths give zero. Throws `CancellationError` when the surrounding task is cancelled.
    public static func size(of url: URL) async throws -> SizeResult {
        try Task.checkCancellation()
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return SizeResult(bytes: 0) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return SizeResult(bytes: Int64(st.st_blocks) * 512) }

        let seen = InodeSet()
        var total = Int64(st.st_blocks) * 512
        var inaccessible = false
        let children: [String]
        do {
            children = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            return SizeResult(bytes: total, inaccessible: true)
        }

        let limit = max(1, ProcessInfo.processInfo.activeProcessorCount)
        try await withThrowingTaskGroup(of: SizeResult.self) { group in
            var iterator = children.makeIterator()
            var running = 0
            func addNext(_ group: inout ThrowingTaskGroup<SizeResult, any Error>) -> Bool {
                guard let child = iterator.next() else { return false }
                let childPath = (path as NSString).appendingPathComponent(child)
                group.addTask { try walk(childPath, seen: seen) }
                return true
            }
            while running < limit, addNext(&group) { running += 1 }
            while let result = try await group.next() {
                total += result.bytes
                inaccessible = inaccessible || result.inaccessible
                if addNext(&group) { continue }
            }
        }
        return SizeResult(bytes: total, inaccessible: inaccessible)
    }

    /// Synchronous `fts` walk of one subtree.
    private static func walk(_ path: String, seen: InodeSet) throws -> SizeResult {
        var total: Int64 = 0
        var inaccessible = false
        guard let cPath = strdup(path) else { return SizeResult(bytes: 0) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return SizeResult(bytes: 0, inaccessible: errno == EACCES || errno == EPERM)
        }
        defer { fts_close(stream) }

        var count = 0
        while let entry = fts_read(stream) {
            count += 1
            if count % 1000 == 0 { try Task.checkCancellation() }
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_DP:
                continue
            case FTS_DNR, FTS_ERR, FTS_NS:
                let err = entry.pointee.fts_errno
                if err == EACCES || err == EPERM { inaccessible = true }
                if info == FTS_DNR, let st = entry.pointee.fts_statp {
                    total += Int64(st.pointee.st_blocks) * 512
                }
            default:
                guard let st = entry.pointee.fts_statp?.pointee else { continue }
                if st.st_nlink > 1 && (st.st_mode & S_IFMT) != S_IFDIR && !seen.insert(dev: st.st_dev, ino: st.st_ino) {
                    continue
                }
                total += Int64(st.st_blocks) * 512
            }
        }
        try Task.checkCancellation()
        return SizeResult(bytes: total, inaccessible: inaccessible)
    }
}

/// `(dev, ino)` pairs already counted, shared by all subtrees of one sizing call.
private final class InodeSet: @unchecked Sendable {
    private struct Key: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    private let lock = NSLock()
    private var keys: Set<Key> = []

    /// True when the pair was not seen before.
    func insert(dev: dev_t, ino: ino_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.insert(Key(dev: Int32(dev), ino: UInt64(ino))).inserted
    }
}
