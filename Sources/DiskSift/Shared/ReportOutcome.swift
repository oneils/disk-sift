import SiftCore

/// Which action a report describes; decides its wording, independent of how items were removed.
enum ReportContext: Equatable {
    case uninstall
    case cleanup
    case largeFiles

    /// How items of this action are removed (amount and note lines follow it).
    var policy: RemovalPolicy { self == .cleanup ? .delete : .trash }
}

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

    init(_ report: RemovalReport) {
        // only an uninstall produces appNotRemoved: the app itself stayed, so the action failed
        let appFailed = report.skipped.contains { $0.reason == .appNotRemoved }
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
    func titleKey(context: ReportContext) -> String {
        switch (self, context) {
        case (.success, .uninstall): "Uninstall finished"
        case (.partial, .uninstall): "Uninstall partly finished"
        case (.stopped, .uninstall): "Uninstall stopped"
        case (.failed, .uninstall): "Uninstall failed"
        case (.success, .cleanup): "Cleanup finished"
        case (.partial, .cleanup): "Cleanup partly finished"
        case (.stopped, .cleanup): "Cleanup stopped"
        case (.failed, .cleanup): "Cleanup failed"
        case (.success, .largeFiles): "Files moved to Trash"
        case (.partial, .largeFiles): "Some files moved to Trash"
        case (.stopped, .largeFiles): "Moving to Trash stopped"
        case (.failed, .largeFiles): "Files were not moved to Trash"
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
        case .notAFile: "Not a regular file"
        case .policyNotAllowed: "Permanent deletion is not allowed here"
        }
    }

    /// English localization key of a suggested next step; nil when there is nothing to do.
    var hintKey: String? {
        switch self {
        case .outsideRoots: "DiskSift only removes items in locations it allows for this action."
        case .needsAdmin: "Remove it in Finder with an administrator account if you no longer need it."
        case .permissionDenied: "Grant Full Disk Access in System Settings, then try again."
        case .inUse: "Quit the app that uses it, then try again."
        case .vanished: nil
        case .appNotRemoved: "Fix the problem with the application above, then uninstall again."
        case .notAFile: "Only files can be moved to the Trash from this list; use Finder for folders and links."
        case .policyNotAllowed: "Items from this list can only be moved to the Trash."
        }
    }
}
