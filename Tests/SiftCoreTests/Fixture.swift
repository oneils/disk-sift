import Foundation

@testable import SiftCore

/// A per-test temp directory with a `SiftPaths` layout under it.
/// The root is resolved with `realpath`, so `/var/folders/...` becomes `/private/var/folders/...`.
/// Permissions changed through `chmod` are restored before the tree is removed.
final class Fixture {
    let root: URL
    let paths: SiftPaths
    private var changedModes: [(URL, mode_t)] = []

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("disksift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = realpath(base.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        paths = SiftPaths(root: root)
        for dir in [
            paths.home, paths.library, paths.systemLibrary, paths.applications, paths.userApplications, paths.tmp,
        ] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        for (url, mode) in changedModes.reversed() {
            Darwin.chmod(url.path, mode)
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// URL for `relative` under the root (no filesystem change).
    func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    @discardableResult
    func mkdir(_ relative: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ relative: String, _ contents: String = "") throws -> URL {
        try write(relative, data: Data(contents.utf8))
    }

    @discardableResult
    func write(_ relative: String, data: Data) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// Creates a symlink at `relative` pointing to `destination` (stored as given).
    @discardableResult
    func symlink(_ relative: String, to destination: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }

    /// Changes the mode of `url`, remembering the original for cleanup.
    func chmod(_ url: URL, _ mode: mode_t) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        changedModes.append((url, st.st_mode & 0o7777))
        guard Darwin.chmod(url.path, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func chmod(_ relative: String, _ mode: mode_t) throws {
        try chmod(url(relative), mode)
    }

    /// Creates a minimal `.app` bundle in `dir` (default `paths.applications`).
    /// Each nested bundle ID becomes a login item helper under `Contents/Library/LoginItems`.
    @discardableResult
    func makeApp(bundleID: String?, name: String, nested: [String] = [], in dir: URL? = nil) throws -> URL {
        let app = (dir ?? paths.applications).appendingPathComponent("\(name).app", isDirectory: true)
        try writeBundle(at: app, bundleID: bundleID, name: name)
        for id in nested {
            let helper = app.appendingPathComponent("Contents/Library/LoginItems/\(id).app", isDirectory: true)
            try writeBundle(at: helper, bundleID: id, name: id)
        }
        return app
    }

    private func writeBundle(at bundle: URL, bundleID: String?, name: String) throws {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS", isDirectory: true), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": name, "CFBundlePackageType": "APPL"]
        if let bundleID {
            plist["CFBundleIdentifier"] = bundleID
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
