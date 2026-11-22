import Foundation

/// Finds files that belong to an app. A known-paths database can be added later as one more source.
public protocol LeftoverSource: Sendable {
    func findings(for app: AppInfo, paths: SiftPaths) async throws -> [Finding]
}
