import Foundation

/// Developer caches that are safe to delete. Only the path list lives here for now;
/// `RemovalRoots` derives its allowed roots from it.
public struct DevJunkCategory: Sendable {
    /// Every dev junk location (missing ones are skipped by the scanner).
    public static func paths(_ paths: SiftPaths) -> [URL] {
        let lib = paths.library
        let home = paths.home
        return [
            lib.appendingPathComponent("Developer/Xcode/DerivedData", isDirectory: true),
            lib.appendingPathComponent("Developer/Xcode/Archives", isDirectory: true),
            lib.appendingPathComponent("Developer/Xcode/iOS DeviceSupport", isDirectory: true),
            lib.appendingPathComponent("Developer/CoreSimulator/Caches", isDirectory: true),
            lib.appendingPathComponent("Caches/Homebrew", isDirectory: true),
            home.appendingPathComponent(".npm/_cacache", isDirectory: true),
            lib.appendingPathComponent("Caches/pip", isDirectory: true),
            home.appendingPathComponent(".cargo/registry/cache", isDirectory: true),
            lib.appendingPathComponent("Caches/go-build", isDirectory: true),
            home.appendingPathComponent("go/pkg/mod", isDirectory: true),
        ]
    }
}
