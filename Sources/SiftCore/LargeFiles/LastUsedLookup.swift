import CoreServices
import Foundation

/// When a file was last opened, as macOS records it (live: Spotlight `kMDItemLastUsedDate`).
/// The file system's access time is not used: APFS barely updates it.
public protocol LastUsedLookup: Sendable {
    /// Nil when unknown (not indexed, never opened through Launch Services).
    func lastUsed(_ url: URL) -> Date?
}

public struct SpotlightLastUsedLookup: LastUsedLookup {
    public init() {}

    public func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
