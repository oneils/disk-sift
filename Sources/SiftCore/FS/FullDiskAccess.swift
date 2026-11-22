import Foundation

public enum FullDiskAccess {
    /// TCC-protected locations, relative to `~/Library`. Without Full Disk Access, opening any of
    /// them fails with `EPERM`. Not every one exists on every system (`TCC.db` is gone on recent
    /// macOS, `Mail`/`Messages` only exist once those apps were used), so several are probed.
    static let probes = [
        "Application Support/com.apple.TCC/TCC.db",
        "Safari",
        "Mail",
        "Messages",
        "Cookies",
        "Suggestions",
        "Metadata/CoreSpotlight",
        "Containers/com.apple.Safari",
    ]

    /// Probes the protected locations in order: the first one that exists decides. Opened → granted;
    /// `EPERM`/`EACCES` → not granted; missing (or any other error) → try the next one. When none
    /// exists there is nothing to tell by, so access is assumed rather than nagging with a false banner.
    public static func isGranted(_ paths: SiftPaths) -> Bool {
        for probe in probes {
            let path = paths.library.appendingPathComponent(probe).path
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            let err = errno
            if err == EPERM || err == EACCES { return false }
        }
        return true
    }
}
