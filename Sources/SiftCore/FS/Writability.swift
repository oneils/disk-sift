import Foundation

/// Whether the current user can remove an item without elevated rights.
public enum Writability {
    /// Removing needs write + search on the parent; a sticky parent also requires owning the item;
    /// moving a directory to the Trash needs write on the directory itself (its `..` entry changes).
    public static func canRemove(_ url: URL, policy: RemovalPolicy) -> Bool {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }

        let parent = (path as NSString).deletingLastPathComponent
        guard access(parent, W_OK | X_OK) == 0 else { return false }

        var parentStat = stat()
        guard stat(parent, &parentStat) == 0 else { return false }
        if parentStat.st_mode & mode_t(S_ISVTX) != 0 {
            let uid = geteuid()
            if uid != 0 && st.st_uid != uid { return false }
        }

        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        if policy == .trash && isDirectory {
            return access(path, W_OK) == 0
        }
        return true
    }

    /// The user can move `url` to the Trash and later empty it: `canRemove(.trash)`, and every directory
    /// inside is writable and searchable (a root-owned 755 subfolder would be stuck in the Trash).
    /// A sticky directory also requires owning each of its entries. Symlinks are never followed.
    public static func canTrashDeep(_ url: URL) -> Bool {
        guard canRemove(url, policy: .trash) else { return false }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return true }
        let uid = geteuid()
        var ok = true
        url.path.withCString { start in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(start), nil]
            defer { free(argv[0]) }
            guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
                ok = false
                return
            }
            defer { fts_close(stream) }
            while ok, let entry = fts_read(stream) {
                switch Int32(entry.pointee.fts_info) {
                case FTS_D:
                    let path = String(cString: entry.pointee.fts_path)
                    if access(path, W_OK | X_OK) != 0 { ok = false }
                    if let s = entry.pointee.fts_statp, s.pointee.st_mode & mode_t(S_ISVTX) != 0, uid != 0 {
                        // every entry of a sticky directory must be ours; check them via the directory listing
                        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                        for name in names {
                            var child = stat()
                            if lstat(path + "/" + name, &child) == 0, child.st_uid != uid { ok = false }
                        }
                    }
                case FTS_DNR, FTS_ERR, FTS_NS:
                    ok = false
                default:
                    break
                }
            }
        }
        return ok
    }
}
