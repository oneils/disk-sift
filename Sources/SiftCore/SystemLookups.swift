import Foundation

/// Looks up other installed apps by bundle ID (live: NSWorkspace / LaunchServices).
public protocol InstalledApps: Sendable {
    /// True when an app with `bundleID` is installed somewhere other than `excluding`.
    func isInstalled(bundleID: String, excluding: URL) -> Bool
}

/// A currently running application.
public struct RunningApp: Equatable, Hashable, Sendable {
    public var bundleID: String?
    public var bundleURL: URL?
    public var pid: Int32

    public init(bundleID: String?, bundleURL: URL?, pid: Int32) {
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.pid = pid
    }
}

/// Lists running applications (live: NSWorkspace).
public protocol RunningApps: Sendable {
    func running() -> [RunningApp]
}
