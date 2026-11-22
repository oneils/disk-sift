import Foundation

/// Developer caches that are safe to delete. `RemovalRoots` derives its allowed roots from `paths`.
public struct DevJunkCategory: JunkCategory {
    public static let categoryID = "devJunk"
    public let id = DevJunkCategory.categoryID
    public let title = "Developer caches"
    public let policy = RemovalPolicy.delete

    public init() {}

    public func scan(paths: SiftPaths) async throws -> [Finding] {
        try Task.checkCancellation()
        return Self.paths(paths).compactMap { JunkSupport.finding($0, categoryID: id, paths: paths) }
    }

    /// Xcode Archives hold dSYMs, so they stay unchecked.
    public func checkedByDefault(_ finding: Finding, running: [RunningApp]) -> Bool {
        !finding.requiresRoot && finding.url.lastPathComponent != "Archives"
    }

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
