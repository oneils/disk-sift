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
}
