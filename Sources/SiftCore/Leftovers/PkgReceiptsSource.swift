import Foundation

/// Finds files installed by `.pkg` receipts whose package ID belongs to the app.
/// Only paths strictly inside a leftover scan dir are reported (never shared vendor dirs or `/usr/local`).
public struct PkgReceiptsSource: LeftoverSource {
    private let runner: any CommandRunner
    private static let pkgutil = "/usr/sbin/pkgutil"

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func findings(for app: AppInfo, paths: SiftPaths) async throws -> [Finding] {
        do {
            return try await scan(app, paths)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.scan.error("pkgutil scan failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func scan(_ app: AppInfo, _ paths: SiftPaths) async throws -> [Finding] {
        let ids = ([app.bundleID] + app.nestedBundleIDs).map { $0.lowercased() }
        let list = try await runner.run(Self.pkgutil, ["--pkgs"])
        guard list.status == 0 else { return [] }
        let pkgs = list.stdout.split(separator: "\n").map(String.init).filter { pkg in
            let lower = pkg.lowercased()
            return ids.contains { lower == $0 || lower.hasPrefix($0 + ".") }
        }
        let scanDirs = ScanLocations.leftoverDirs(paths).map { $0.path }
        var found: [String: Finding] = [:]
        for pkg in pkgs {
            try Task.checkCancellation()
            let info = try await runner.run(Self.pkgutil, ["--pkg-info", pkg])
            let files = try await runner.run(Self.pkgutil, ["--files", pkg])
            guard info.status == 0, files.status == 0 else { continue }
            let base = Self.basePath(info.stdout)
            let listed = Set(
                files.stdout.split(separator: "\n").map {
                    URL(fileURLWithPath: base).appendingPathComponent(String($0)).path
                })
            let inside = listed.filter { path in
                scanDirs.contains { path.hasPrefix($0 + "/") }
            }
            for path in Self.topMost(inside, listed: listed) {
                let url = URL(fileURLWithPath: path)
                found[path] = Finding(
                    url: url, confidence: .low, sources: [.pkgReceipt],
                    requiresRoot: !Writability.canRemove(url, policy: .trash), evidence: [.pkgReceipt])
            }
        }
        return found.values.sorted { $0.url.path < $1.url.path }
    }

    /// `volume` + `location` from `pkgutil --pkg-info` (`location` may be empty).
    private static func basePath(_ info: String) -> String {
        var volume = "/"
        var location = ""
        for line in info.split(separator: "\n") {
            if line.hasPrefix("volume:") {
                volume = line.dropFirst("volume:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("location:") {
                location = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return URL(fileURLWithPath: volume).appendingPathComponent(location).path
    }

    /// Existing top-most paths. A directory is reported as a whole only when everything in it on disk
    /// was installed by the package; otherwise it is shared (a vendor dir) and its listed children are used.
    private static func topMost(_ candidates: Set<String>, listed: Set<String>) -> [String] {
        let tops = candidates.filter { path in
            let parent = (path as NSString).deletingLastPathComponent
            return !candidates.contains(parent)
        }
        return tops.sorted().flatMap { resolve($0, listed: listed) }
    }

    private static func resolve(_ path: String, listed: Set<String>) -> [String] {
        var isDir: ObjCBool = false
        var st = stat()
        guard lstat(path, &st) == 0 else { return [] }
        let isRealDir = (st.st_mode & S_IFMT) == S_IFDIR
        isDir = ObjCBool(isRealDir)
        guard isDir.boolValue else { return [path] }
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
        let childPaths = children.map { (path as NSString).appendingPathComponent($0) }
        let resolved = childPaths.map { listed.contains($0) ? resolve($0, listed: listed) : nil }
        let complete = zip(childPaths, resolved).allSatisfy { child, result in result == [child] }
        if complete { return [path] }
        return resolved.compactMap { $0 }.flatMap { $0 }
    }
}
