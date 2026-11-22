import Foundation

/// Moves an item to the Trash. Faked in tests.
public protocol Trasher: Sendable {
    func trash(_ url: URL) throws
}

public struct FileManagerTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
