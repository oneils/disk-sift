import Foundation

/// Where the Large Files report may look and what it may move to the Trash: anything strictly inside
/// the home folder, on the home volume, except places owned by other features or whose files only make
/// sense as a whole (packages, Git repositories).
///
/// The scanner uses `shouldSkipDirectory` to avoid walking denied subtrees; `Remover` (through
/// `RemovalRoots.largeFiles`) uses `isDenied` and stays the only authority on what may be removed.
public struct LargeFilesScope: Sendable, Equatable {
    /// Canonical home folder.
    public let home: CanonicalPath
    /// Device of the home folder; nil when it can't be read, which denies everything.
    let homeDevice: dev_t?

    /// Direct children of home that are never offered: Library belongs to uninstall/junk (and holds
    /// iCloud Drive and CloudStorage), the Trash is already trash, apps go through Uninstall.
    static let deniedHomeChildren: Set<String> = ["library", ".trash", "applications"]

    /// Directories whose contents only make sense as a whole. Listed explicitly because `isPackageKey`
    /// depends on Launch Services and stops working once the owning app is gone.
    public static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "fcpbundle", "imovielibrary", "tvlibrary", "bundle", "framework",
        "pvm", "vmwarevm", "utm", "sparsebundle", "logicx", "aplibrary", "dtbase2",
    ]

    public init(paths: SiftPaths) {
        let home = RemovalRoots.canonicalRoot(paths.home)
        var st = stat()
        self.init(home: home, homeDevice: lstat(home.path, &st) == 0 ? st.st_dev : nil)
    }

    init(home: CanonicalPath, homeDevice: dev_t?) {
        self.home = home
        self.homeDevice = homeDevice
    }

    /// True when `path` must not be removed: outside home or home itself, inside a denied home child,
    /// below a package or `.git` directory, or on another volume.
    public func isDenied(_ path: CanonicalPath) -> Bool {
        guard path.isStrictlyInside(home) else { return true }
        let relative = Array(path.path.split(separator: "/").dropFirst(home.path.split(separator: "/").count))
            .map(String.init)
        guard let first = relative.first, !Self.deniedHomeChildren.contains(first.lowercased()) else { return true }
        var ancestor = home.url
        for component in relative.dropLast() {
            ancestor.appendPathComponent(component)
            if Self.isOpaque(name: component) || Self.isRegisteredPackage(ancestor) { return true }
        }
        return !isOnHomeVolume(path.path)
    }

    /// Whether the scanner should not descend into `directory` (its canonical path, as enumerated).
    public func shouldSkipDirectory(_ directory: URL, isPackage: Bool, device: dev_t?) -> Bool {
        if isPackage || Self.isOpaque(name: directory.lastPathComponent) { return true }
        if let homeDevice, let device, device != homeDevice { return true }
        guard let canonical = try? CanonicalPath.of(directory) else { return true }
        if canonical.path.lowercased() == home.path.lowercased() { return false }
        guard canonical.isStrictlyInside(home) else { return true }
        let first = canonical.path.split(separator: "/")[home.path.split(separator: "/").count]
        return Self.deniedHomeChildren.contains(first.lowercased())
    }

    /// A `.git` directory or a known package extension.
    static func isOpaque(name: String) -> Bool {
        let lower = name.lowercased()
        return lower == ".git" || packageExtensions.contains((lower as NSString).pathExtension)
    }

    private static func isRegisteredPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// A missing path is not denied here: `Remover` reports it as vanished.
    private func isOnHomeVolume(_ path: String) -> Bool {
        guard let homeDevice else { return false }
        var st = stat()
        guard lstat(path, &st) == 0 else { return true }
        return st.st_dev == homeDevice
    }
}
