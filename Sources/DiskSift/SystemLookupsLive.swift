import AppKit
import SiftCore

struct LiveInstalledApps: InstalledApps {
    func isInstalled(bundleID: String, excluding: URL) -> Bool {
        let excluded = excluding.standardizedFileURL.path
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .contains { !$0.standardizedFileURL.path.hasPrefix(excluded) }
    }

    func isKnownOutsideTrash(bundleID: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .contains { !TrashCheck.isInTrash($0, home: home) }
    }
}

struct LiveRunningApps: RunningApps {
    func running() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map {
            RunningApp(bundleID: $0.bundleIdentifier, bundleURL: $0.bundleURL, pid: $0.processIdentifier)
        }
    }
}
