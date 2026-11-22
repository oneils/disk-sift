import SiftCore

/// How a removal ended, for the report headline and symbol.
enum ReportOutcome: Equatable {
    /// Everything requested was removed.
    case success
    /// Some items were removed, some skipped.
    case partial
    /// Stopped by the user before all items were processed.
    case stopped
    /// Nothing was removed (or, for an uninstall, the app itself could not be moved).
    case failed

    init(_ report: RemovalReport, policy: RemovalPolicy) {
        let appFailed = policy == .trash && report.skipped.contains { $0.reason == .appNotRemoved }
        if report.stopped && !report.unprocessed.isEmpty {
            self = .stopped
        } else if appFailed || (report.removed.isEmpty && !report.skipped.isEmpty) {
            self = .failed
        } else if report.skipped.isEmpty {
            self = .success
        } else {
            self = .partial
        }
    }

    /// English localization key of the sheet title.
    func titleKey(policy: RemovalPolicy) -> String {
        switch (self, policy) {
        case (.success, .trash): "Uninstall finished"
        case (.partial, .trash): "Uninstall partly finished"
        case (.stopped, .trash): "Uninstall stopped"
        case (.failed, .trash): "Uninstall failed"
        case (.success, .delete): "Cleanup finished"
        case (.partial, .delete): "Cleanup partly finished"
        case (.stopped, .delete): "Cleanup stopped"
        case (.failed, .delete): "Cleanup failed"
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
}

extension SkipReason {
    /// English localization key of the reason.
    var titleKey: String {
        switch self {
        case .outsideRoots: "Outside the allowed locations"
        case .needsAdmin: "Needs administrator rights"
        case .permissionDenied: "Permission denied"
        case .inUse: "In use"
        case .vanished: "Already gone"
        case .appNotRemoved: "Left alone because the app could not be removed"
        }
    }

    /// English localization key of a suggested next step; nil when there is nothing to do.
    var hintKey: String? {
        switch self {
        case .outsideRoots: "DiskSift only removes items inside known Library locations."
        case .needsAdmin: "Remove it in Finder with an administrator account if you no longer need it."
        case .permissionDenied: "Grant Full Disk Access in System Settings, then try again."
        case .inUse: "Quit the app that uses it, then try again."
        case .vanished: nil
        case .appNotRemoved: "Fix the problem with the application above, then uninstall again."
        }
    }
}
