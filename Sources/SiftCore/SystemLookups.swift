import Foundation

/// Looks up other installed apps by bundle ID (live: NSWorkspace / LaunchServices).
public protocol InstalledApps: Sendable {
    /// True when an app with `bundleID` is installed somewhere other than `excluding`.
    func isInstalled(bundleID: String, excluding: URL) -> Bool
    /// True when Launch Services knows an app with `bundleID` that is not sitting in a Trash.
    /// An app dragged to the Trash (not emptied yet) is still registered, but it is gone for the user.
    func isKnownOutsideTrash(bundleID: String) -> Bool
}

public enum TrashCheck {
    /// Inside the user's `~/.Trash` or a volume's `.Trashes` folder.
    public static func isInTrash(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let trash = home.appendingPathComponent(".Trash").standardizedFileURL.path
        if path == trash || path.hasPrefix(trash + "/") { return true }
        return url.standardizedFileURL.pathComponents.contains(".Trashes")
    }
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
