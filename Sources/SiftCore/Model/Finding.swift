import Foundation

/// How sure we are that a finding belongs to the app being uninstalled (or is safe junk).
public enum Confidence: Int, Comparable, Sendable, CaseIterable {
    case low
    case medium
    case high

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// launchd domain a launch item lives in.
public enum LaunchDomain: String, Hashable, Sendable {
    /// `~/Library/LaunchAgents`, unloadable with `launchctl bootout gui/<uid>/<label>`.
    case user
    /// `/Library/LaunchAgents`, `/Library/LaunchDaemons`; root-only.
    case system
}

/// Why a path was reported.
public enum FindingSource: Hashable, Sendable {
    case libraryPath
    case groupContainer
    case launchItem(label: String, domain: LaunchDomain)
    case pkgReceipt
    case junk(categoryID: String)
    /// A file from the Large Files report.
    case largeFile
}

/// The concrete match behind a finding, so the UI can explain it instead of showing a bare confidence.
public enum MatchEvidence: Hashable, Sendable, CaseIterable {
    /// Named after the app's (or a nested helper's) bundle ID.
    case bundleIDName
    /// Named like the app, with no bundle ID in the name.
    case appName
    /// An app group container listed in the app's signature; other apps of the developer can share it.
    case appGroup
    /// Starts with the developer's Team ID; may belong to any app of that developer.
    case teamPrefix
    /// Another installed app owns a longer bundle ID matching the name.
    case otherAppInstalled
    /// A launchd job whose label matches one of the app's bundle IDs.
    case launchLabel
    /// A launchd job that runs a program inside the app bundle.
    case launchProgramInApp
    /// A launchd job for a privileged helper named after the app.
    case privilegedHelper
    /// Installed by a `.pkg` whose package ID matches the app.
    case pkgReceipt

    /// Data other apps may also use.
    public var isShared: Bool {
        self == .appGroup || self == .teamPrefix || self == .otherAppInstalled
    }
}

/// A file or directory found by a scanner.
public struct Finding: Identifiable, Hashable, Sendable {
    public var url: URL
    /// Allocated bytes; `nil` until sized (or when sizing failed).
    public var size: Int64?
    public var confidence: Confidence
    public var sources: Set<FindingSource>
    /// The current user can't remove it; never attempted.
    public var requiresRoot: Bool
    /// Some of it couldn't be read (size is partial or unknown).
    public var inaccessible: Bool
    /// Why it matched (leftovers only).
    public var evidence: Set<MatchEvidence>
    /// Readable name when the file name means nothing (an iOS backup's device name and date).
    public var displayName: String?

    public var id: String { url.path }

    /// Other apps may use this data too.
    public var isShared: Bool { evidence.contains { $0.isShared } }

    public init(
        url: URL, size: Int64? = nil, confidence: Confidence, sources: Set<FindingSource>,
        requiresRoot: Bool = false, inaccessible: Bool = false, evidence: Set<MatchEvidence> = [],
        displayName: String? = nil
    ) {
        self.url = url
        self.size = size
        self.confidence = confidence
        self.sources = sources
        self.requiresRoot = requiresRoot
        self.inaccessible = inaccessible
        self.evidence = evidence
        self.displayName = displayName
    }
}

/// What happens to removed items.
public enum RemovalPolicy: Sendable {
    /// Move to the Trash (uninstall).
    case trash
    /// Delete permanently (junk).
    case delete
}

/// Why an item was not removed.
public enum SkipReason: Equatable, Sendable {
    case outsideRoots
    case needsAdmin
    case permissionDenied
    case inUse
    case vanished
    /// The app itself couldn't be trashed, so its leftovers were left alone.
    case appNotRemoved
    /// The removal scope only accepts regular files (directories and symlinks are refused).
    case notAFile
    /// The removal scope doesn't allow this policy (permanent deletion in a Trash-only scope).
    case policyNotAllowed
}

public struct RemovedItem: Equatable, Sendable {
    public var url: URL
    public var size: Int64?

    public init(url: URL, size: Int64?) {
        self.url = url
        self.size = size
    }
}

public struct SkippedItem: Equatable, Sendable {
    public var url: URL
    public var reason: SkipReason

    public init(url: URL, reason: SkipReason) {
        self.url = url
        self.reason = reason
    }
}

public struct RemovalProgressState: Equatable, Sendable {
    public var current: Finding
    public var completed: Int
    public var total: Int
    public var processedBytes: Int64

    public init(current: Finding, completed: Int, total: Int, processedBytes: Int64) {
        self.current = current
        self.completed = completed
        self.total = total
        self.processedBytes = processedBytes
    }
}

public enum RemovalProgress: Equatable, Sendable {
    case step(RemovalProgressState)
    case completed(report: RemovalReport)
}

public struct RemovalReport: Equatable, Sendable {
    public var removed: [RemovedItem]
    public var skipped: [SkippedItem]
    public var unprocessed: [Finding]
    public var stopped: Bool

    public init(
        removed: [RemovedItem] = [],
        skipped: [SkippedItem] = [],
        unprocessed: [Finding] = [],
        stopped: Bool = false
    ) {
        self.removed = removed
        self.skipped = skipped
        self.unprocessed = unprocessed
        self.stopped = stopped
    }
}
