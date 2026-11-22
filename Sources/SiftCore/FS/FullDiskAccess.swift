import Foundation

public enum FullDiskAccess {
    /// Probes whether `TCC.db` can be opened for reading. It always exists, and only apps with
    /// Full Disk Access may read it (`EPERM`/`EACCES` otherwise). Any failure counts as "not granted".
    public static func isGranted(_ paths: SiftPaths) -> Bool {
        let db = paths.library.appendingPathComponent("Application Support/com.apple.TCC/TCC.db")
        let fd = open(db.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}
