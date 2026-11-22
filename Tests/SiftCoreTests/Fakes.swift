import Foundation

@testable import SiftCore

/// Bundle IDs of "other installed apps".
struct FakeInstalledApps: InstalledApps {
    var bundleIDs: Set<String> = []

    func isInstalled(bundleID: String, excluding: URL) -> Bool {
        bundleIDs.contains(bundleID)
    }
}

struct FakeRunningApps: RunningApps {
    var apps: [RunningApp] = []

    func running() -> [RunningApp] {
        apps
    }
}
