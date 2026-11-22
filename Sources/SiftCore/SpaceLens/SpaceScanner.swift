import Foundation

/// Walks a folder once (physical, one volume, hard links counted once) and builds a `SpaceTree`.
/// Directories always get a node; files only from `minimumFileSize`, the rest of a directory's files are
/// summed into one `otherFiles` node. Packages and `.git` are sized as a whole and never entered.
public struct SpaceScanner: Sendable {
    public struct Progress: Sendable, Equatable {
        public var items: Int
        public var bytes: Int64

        public init(items: Int, bytes: Int64) {
            self.items = items
            self.bytes = bytes
        }
    }

    public static let defaultMinimumFileSize: Int64 = 1_000_000

    private let root: URL
    private let minimumFileSize: Int64

    public init(root: URL, minimumFileSize: Int64 = SpaceScanner.defaultMinimumFileSize) {
        self.root = root
        self.minimumFileSize = minimumFileSize
    }

    /// The home folder of `paths`.
    public init(paths: SiftPaths) {
        self.init(root: paths.home)
    }

    /// Runs off the caller's executor. Throws `CancellationError` when cancelled.
    public func scan(progress: (@Sendable (Progress) -> Void)? = nil) async throws -> SpaceTree {
        let root = root
        let minimum = minimumFileSize
        let walk = Task.detached(priority: .userInitiated) {
            try Self.walk(root: root, minimumFileSize: minimum, progress: progress)
        }
        // a detached task doesn't inherit cancellation: forward it
        return try await withTaskCancellationHandler {
            try await walk.value
        } onCancel: {
            walk.cancel()
        }
    }

    private struct Pending {
        var smallCount = 0
        var smallBytes: Int64 = 0
    }

    static func walk(root: URL, minimumFileSize: Int64, progress: (@Sendable (Progress) -> Void)?) throws
        -> SpaceTree
    {
        let rootPath = RemovalRoots.canonicalRoot(root).path
        var nodes: [SpaceNode] = [
            SpaceNode(name: rootPath, parent: -1, kind: .directory, size: 0, children: [], inaccessible: false)
        ]
        var pending: [Int32: Pending] = [:]
        var seenLinks = Set<String>()
        var items = 0
        var bytes: Int64 = 0
        // fts level -> node index of the open directory at that level
        var open: [Int32] = [0]
        // level of the package being summed as a whole, if inside one
        var collapsedLevel: Int?

        if Task.isCancelled { throw CancellationError() }

        /// Post-order close of the directory open at `level`: fold in its small files, pass its size up.
        func close(level: Int) {
            guard level < open.count else { return }
            let index = open[level]
            if let small = pending.removeValue(forKey: index), small.smallCount > 0 {
                let other = Int32(nodes.count)
                nodes.append(
                    SpaceNode(
                        name: "", parent: index, kind: .otherFiles(count: small.smallCount),
                        size: small.smallBytes, children: [], inaccessible: false))
                nodes[Int(index)].children.append(other)
                nodes[Int(index)].size += small.smallBytes
            }
            if level > 0 {
                let parent = nodes[Int(index)].parent
                nodes[Int(parent)].size += nodes[Int(index)].size
                if nodes[Int(index)].inaccessible { nodes[Int(parent)].inaccessible = true }
            }
        }

        var cancelled = false
        rootPath.withCString { start in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(start), nil]
            defer { free(argv[0]) }
            guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return }
            defer { fts_close(stream) }
            while let entry = fts_read(stream) {
                items += 1
                if items % 4096 == 0 {
                    if Task.isCancelled {
                        cancelled = true
                        return
                    }
                    progress?(Progress(items: items, bytes: bytes))
                }
                let level = Int(entry.pointee.fts_level)
                let info = Int32(entry.pointee.fts_info)
                let allocated: Int64 =
                    entry.pointee.fts_statp.map { Int64($0.pointee.st_blocks) * 512 } ?? 0

                if let collapsed = collapsedLevel, level > collapsed {
                    // inside a package: everything adds to the package node
                    if info == FTS_DP { continue }
                    if info != FTS_D, isDuplicateLink(entry, &seenLinks) { continue }
                    nodes[Int(open[collapsed])].size += allocated
                    bytes += allocated
                    if info == FTS_DNR || info == FTS_ERR { nodes[Int(open[collapsed])].inaccessible = true }
                    continue
                }

                switch info {
                case FTS_D:
                    let name = entryName(entry)
                    if level == 0 {
                        nodes[0].size += allocated
                        bytes += allocated
                        continue
                    }
                    let parent = open[level - 1]
                    let opaque = LargeFilesScope.isOpaque(name: name)
                    let index = Int32(nodes.count)
                    nodes.append(
                        SpaceNode(
                            name: name, parent: parent, kind: opaque ? .package : .directory, size: allocated,
                            children: [], inaccessible: false))
                    nodes[Int(parent)].children.append(index)
                    bytes += allocated
                    if open.count > level { open[level] = index } else { open.append(index) }
                    if opaque { collapsedLevel = level }
                case FTS_DP:
                    if let collapsed = collapsedLevel, level == collapsed { collapsedLevel = nil }
                    close(level: level)
                case FTS_DNR:
                    // an unreadable directory (no Full Disk Access, permissions), reported after its FTS_D
                    // in place of FTS_DP: its size is partial
                    if level == 0 {
                        nodes[0].inaccessible = true
                    } else if level < open.count, nodes[Int(open[level])].name == entryName(entry) {
                        nodes[Int(open[level])].inaccessible = true
                        close(level: level)
                    } else {
                        nodes[Int(open[level - 1])].inaccessible = true
                    }
                case FTS_ERR:
                    nodes[Int(level > 0 ? open[level - 1] : 0)].inaccessible = true
                case FTS_NS:
                    nodes[Int(level > 0 ? open[level - 1] : 0)].inaccessible = true
                default:
                    // files, symlinks (as links), others
                    guard level > 0 else { continue }
                    if isDuplicateLink(entry, &seenLinks) { continue }
                    let parent = open[level - 1]
                    bytes += allocated
                    if info == FTS_F && allocated >= minimumFileSize {
                        let index = Int32(nodes.count)
                        nodes.append(
                            SpaceNode(
                                name: entryName(entry), parent: parent, kind: .file,
                                size: allocated, children: [], inaccessible: false))
                        nodes[Int(parent)].children.append(index)
                        nodes[Int(parent)].size += allocated
                    } else {
                        pending[parent, default: Pending()].smallCount += 1
                        pending[parent, default: Pending()].smallBytes += allocated
                    }
                }
            }
        }
        if cancelled { throw CancellationError() }
        progress?(Progress(items: items, bytes: bytes))
        return SpaceTree(root: URL(fileURLWithPath: rootPath, isDirectory: true), nodes: nodes)
    }

    /// Last path component; `fts_name` is a flexible array member Swift imports as a single character.
    private static func entryName(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        (String(cString: entry.pointee.fts_path) as NSString).lastPathComponent
    }

    /// A hard link already counted elsewhere in the walk.
    private static func isDuplicateLink(_ entry: UnsafeMutablePointer<FTSENT>, _ seen: inout Set<String>) -> Bool {
        guard let st = entry.pointee.fts_statp, st.pointee.st_nlink > 1,
            (st.pointee.st_mode & S_IFMT) != S_IFDIR
        else { return false }
        return !seen.insert("\(st.pointee.st_dev):\(st.pointee.st_ino)").inserted
    }
}
