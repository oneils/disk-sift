import Foundation

/// Errors raised by the core that are not tied to a single finding.
public enum SiftError: Error, Equatable, Sendable {
    /// The executable could not be started (missing, not executable, ...).
    case commandLaunchFailed(executable: String, reason: String)
}
