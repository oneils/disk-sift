import Foundation

@testable import SiftCore

/// Bundle IDs of "other installed apps".
struct FakeInstalledApps: InstalledApps {
    var bundleIDs: Set<String> = []
    /// IDs Launch Services knows outside the Trash (lowercased).
    var knownOutsideTrash: Set<String> = []

    func isInstalled(bundleID: String, excluding: URL) -> Bool {
        bundleIDs.contains(bundleID)
    }

    func isKnownOutsideTrash(bundleID: String) -> Bool {
        knownOutsideTrash.contains(bundleID.lowercased())
    }
}

struct FakeRunningApps: RunningApps {
    var apps: [RunningApp] = []

    func running() -> [RunningApp] {
        apps
    }
}

/// Last-used dates by path.
struct FakeLastUsedLookup: LastUsedLookup {
    var dates: [String: Date] = [:]

    func lastUsed(_ url: URL) -> Date? {
        dates[url.path]
    }
}
