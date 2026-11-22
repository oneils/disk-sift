import Foundation

/// Matches direct children of the `Library` directories against the app's bundle IDs, groups and name.
public struct LibraryPathsSource: LeftoverSource {
    private let installed: any InstalledApps
    private let hasFullDiskAccess: @Sendable (SiftPaths) -> Bool

    private static let knownExtensions = ["plist", "savedState", "binarycookies"]

    public init(
        installed: any InstalledApps,
        hasFullDiskAccess: @escaping @Sendable (SiftPaths) -> Bool = { FullDiskAccess.isGranted($0) }
    ) {
        self.installed = installed
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    public func findings(for app: AppInfo, paths: SiftPaths) async throws -> [Finding] {
        let fda = hasFullDiskAccess(paths)
        let protectedPaths = Set(ScanLocations.protectedDirs(paths).map { $0.standardizedFileURL.path })
        let launchPaths = Set(ScanLocations.launchDirs(paths).map { $0.standardizedFileURL.path })
        let groupsPath = ScanLocations.groupContainersDir(paths).standardizedFileURL.path
        let ids = [app.bundleID] + app.nestedBundleIDs
        var result: [Finding] = []
        for dir in ScanLocations.leftoverDirs(paths) {
            try Task.checkCancellation()
            let dirPath = dir.standardizedFileURL.path
            if launchPaths.contains(dirPath) { continue }
            if protectedPaths.contains(dirPath) && !fda {
                Log.scan.info("skipping \(dirPath, privacy: .public): no Full Disk Access")
                continue
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dirPath))?.sorted() ?? []
            for name in names {
                let isGroup = dirPath == groupsPath
                guard let (confidence, evidence) = match(name, isGroupContainer: isGroup, app: app, ids: ids)
                else { continue }
                let url = dir.appendingPathComponent(name)
                result.append(
                    Finding(
                        url: url, confidence: confidence,
                        sources: [isGroup && confidence == .high ? .groupContainer : .libraryPath],
                        requiresRoot: !Writability.canRemove(url, policy: .trash), evidence: evidence))
            }
        }
        return result
    }

    private func match(
        _ name: String, isGroupContainer: Bool, app: AppInfo, ids: [String]
    ) -> (Confidence, Set<MatchEvidence>)? {
        if isGroupContainer {
            if app.signing.appGroups.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return (.high, [.appGroup])
            }
            if let team = app.signing.teamID, name.lowercased().hasPrefix(team.lowercased() + ".") {
                return (.low, [.teamPrefix])
            }
        }
        let stripped = Self.strippedName(name)
        let lower = stripped.lowercased()
        if let id = ids.first(where: { Self.matches(lower, id: $0.lowercased()) }) {
            return isOtherAppsData(lower, ownID: id.lowercased(), app: app)
                ? (.low, [.bundleIDName, .otherAppInstalled]) : (.high, [.bundleIDName])
        }
        if stripped.count >= 4 && lower == app.name.lowercased() {
            return (.low, [.appName])
        }
        return nil
    }

    private static func matches(_ name: String, id: String) -> Bool {
        name == id || name.hasPrefix(id + ".")
    }

    /// `com.foo.App.Lite` while uninstalling `com.foo.App`: another installed app owns a longer prefix of the name.
    private func isOtherAppsData(_ lowerName: String, ownID: String, app: AppInfo) -> Bool {
        var candidate = lowerName
        while candidate.count > ownID.count {
            if installed.isInstalled(bundleID: candidate, excluding: app.url) { return true }
            guard let dot = candidate.lastIndex(of: ".") else { break }
            candidate = String(candidate[..<dot])
        }
        return false
    }

    private static func strippedName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        if knownExtensions.contains(ext) {
            return (name as NSString).deletingPathExtension
        }
        return name
    }
}
