import Foundation

/// All filesystem locations DiskSift reads from or removes in.
/// Injected everywhere so the core runs against temp-dir fixtures in tests.
public struct SiftPaths: Sendable, Equatable {
    public var home: URL
    public var library: URL
    public var systemLibrary: URL
    public var applications: URL
    public var userApplications: URL
    public var tmp: URL

    public init(
        home: URL,
        library: URL,
        systemLibrary: URL,
        applications: URL,
        userApplications: URL,
        tmp: URL
    ) {
        self.home = home
        self.library = library
        self.systemLibrary = systemLibrary
        self.applications = applications
        self.userApplications = userApplications
        self.tmp = tmp
    }

    /// Layout rooted at `root`, mirroring the real one:
    /// `root/home`, `root/home/Library`, `root/Library`, `root/Applications`, `root/home/Applications`, `root/tmp`.
    public init(root: URL) {
        let home = root.appendingPathComponent("home", isDirectory: true)
        self.init(
            home: home,
            library: home.appendingPathComponent("Library", isDirectory: true),
            systemLibrary: root.appendingPathComponent("Library", isDirectory: true),
            applications: root.appendingPathComponent("Applications", isDirectory: true),
            userApplications: home.appendingPathComponent("Applications", isDirectory: true),
            tmp: root.appendingPathComponent("tmp", isDirectory: true)
        )
    }

    /// The real locations of the current user.
    public static let live: SiftPaths = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SiftPaths(
            home: home,
            library: home.appendingPathComponent("Library", isDirectory: true),
            systemLibrary: URL(fileURLWithPath: "/Library", isDirectory: true),
            applications: URL(fileURLWithPath: "/Applications", isDirectory: true),
            userApplications: home.appendingPathComponent("Applications", isDirectory: true),
            tmp: FileManager.default.temporaryDirectory
        )
    }()
}
