import Foundation

/// Findings that share a parent directory (e.g. everything under `~/Library/Caches`).
public struct FindingGroup: Identifiable, Equatable, Sendable {
    public var parent: URL
    /// Sorted by path.
    public var findings: [Finding]

    public var id: String { parent.path }

    /// Sum of the known sizes.
    public var totalSize: Int64 { findings.reduce(0) { $0 + ($1.size ?? 0) } }

    /// True when at least one finding has no size, i.e. `totalSize` is a lower bound.
    public var hasUnknownSize: Bool { findings.contains { $0.size == nil } }

    public init(parent: URL, findings: [Finding]) {
        self.parent = parent
        self.findings = findings
    }

    /// Groups findings by parent directory; groups are sorted by parent path, findings by path.
    public static func group(_ findings: [Finding]) -> [FindingGroup] {
        var byParent: [String: [Finding]] = [:]
        for finding in findings {
            let parent = finding.url.standardizedFileURL.deletingLastPathComponent().path
            byParent[parent, default: []].append(finding)
        }
        return byParent.keys.sorted().map { parent in
            let sorted = byParent[parent]!.sorted { $0.url.path < $1.url.path }
            return FindingGroup(parent: URL(fileURLWithPath: parent, isDirectory: true), findings: sorted)
        }
    }
}
