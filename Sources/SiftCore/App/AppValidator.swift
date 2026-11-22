import Foundation

/// Decides whether a dropped `.app` may be uninstalled.
public struct AppValidator: Sendable {
    public static let selfBundleID = "dev.disksift.DiskSift"

    public var paths: SiftPaths
    public var readSigning: @Sendable (URL) -> SigningInfo

    public init(paths: SiftPaths = .live, readSigning: @escaping @Sendable (URL) -> SigningInfo = SigningInfo.read) {
        self.paths = paths
        self.readSigning = readSigning
    }

    public func validate(_ url: URL) throws -> AppInfo {
        guard url.pathExtension == "app" else { throw ValidationError.notAnApp }
        let path = url.standardizedFileURL.path
        if path == "/Volumes" || path.hasPrefix("/Volumes/") { throw ValidationError.onVolume }
        if path.contains("/AppTranslocation/") { throw ValidationError.translocated }

        var st = stat()
        guard lstat(path, &st) == 0 else { throw ValidationError.notFound }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw ValidationError.symlink }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ValidationError.notAnApp }

        try checkLocation(url)

        let signing = readSigning(url)
        let info = try AppInfo.load(url, signing: signing)
        if info.bundleID == Self.selfBundleID { throw ValidationError.isSelf }
        if signing.isAppleAnchored { throw ValidationError.appleApp }
        guard Writability.canRemove(url, policy: .trash) else { throw ValidationError.notRemovable }
        return info
    }

    /// Must be below `/Applications` or `~/Applications` with no bundle ancestor in between.
    private func checkLocation(_ url: URL) throws {
        guard let app = try? CanonicalPath.of(url) else { throw ValidationError.outsideApplications }
        for root in [paths.applications, paths.userApplications] {
            guard let canonicalRoot = try? CanonicalPath.of(root), app.isStrictlyInside(canonicalRoot) else {
                continue
            }
            let relative = app.path.dropFirst(canonicalRoot.path.count).split(separator: "/").dropLast()
            let bundleExtensions: Set<String> = ["app", "appex", "xpc", "framework", "bundle", "plugin"]
            if relative.contains(where: {
                bundleExtensions.contains((String($0) as NSString).pathExtension.lowercased())
            }) {
                throw ValidationError.nestedInBundle
            }
            return
        }
        throw ValidationError.outsideApplications
    }
}
