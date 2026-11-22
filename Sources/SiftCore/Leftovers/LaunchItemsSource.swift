import Foundation

/// Finds launchd plists that belong to the app: by `Label`, or by the program they run.
public struct LaunchItemsSource: LeftoverSource {
    public init() {}

    public func findings(for app: AppInfo, paths: SiftPaths) async throws -> [Finding] {
        let ids = ([app.bundleID] + app.nestedBundleIDs).map { $0.lowercased() }
        let appPrefix = app.url.standardizedFileURL.path + "/"
        let helpersDir =
            paths.systemLibrary.appendingPathComponent("PrivilegedHelperTools", isDirectory: true)
            .standardizedFileURL.path + "/"
        let dirs: [(URL, LaunchDomain)] = [
            (paths.library.appendingPathComponent("LaunchAgents", isDirectory: true), .user),
            (paths.systemLibrary.appendingPathComponent("LaunchAgents", isDirectory: true), .system),
            (paths.systemLibrary.appendingPathComponent("LaunchDaemons", isDirectory: true), .system),
        ]
        var result: [Finding] = []
        for (dir, domain) in dirs {
            try Task.checkCancellation()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
            for name in names where (name as NSString).pathExtension == "plist" {
                let url = dir.appendingPathComponent(name)
                guard let plist = Self.readPlist(url) else {
                    Log.scan.info("skipping unreadable launch plist \(url.path, privacy: .public)")
                    continue
                }
                let label = (plist["Label"] as? String) ?? (name as NSString).deletingPathExtension
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                guard
                    Self.matchesID(label, ids: ids)
                        || Self.runsFromApp(program, appPrefix: appPrefix)
                        || Self.isHelper(program, helpersDir: helpersDir, ids: ids)
                else { continue }
                result.append(
                    Finding(
                        url: url, confidence: .high, sources: [.launchItem(label: label, domain: domain)],
                        requiresRoot: domain == .system || !Writability.canRemove(url, policy: .trash)))
            }
        }
        return result
    }

    private static func matchesID(_ name: String, ids: [String]) -> Bool {
        let lower = name.lowercased()
        return ids.contains { lower == $0 || lower.hasPrefix($0 + ".") }
    }

    private static func runsFromApp(_ program: String?, appPrefix: String) -> Bool {
        guard let program else { return false }
        return URL(fileURLWithPath: program).standardizedFileURL.path.hasPrefix(appPrefix)
    }

    /// A `PrivilegedHelperTools` item named after one of the app's bundle IDs.
    private static func isHelper(_ program: String?, helpersDir: String, ids: [String]) -> Bool {
        guard let program else { return false }
        let path = URL(fileURLWithPath: program).standardizedFileURL.path
        guard path.hasPrefix(helpersDir) else { return false }
        let rest = String(path.dropFirst(helpersDir.count))
        return !rest.contains("/") && matchesID(rest, ids: ids)
    }

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
