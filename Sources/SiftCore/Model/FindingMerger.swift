import Foundation

/// Dedupes findings from several sources and collapses findings nested inside other findings.
public enum FindingMerger {
    /// - Exact duplicates (same path): sources and evidence unioned, max confidence, flags OR'ed, largest known size.
    /// - A finding inside another finding is dropped; the ancestor keeps its own confidence and size
    ///   (a large low-confidence folder is not promoted by a high child), sources and evidence are unioned and
    ///   `requiresRoot`/`inaccessible` are OR'ed.
    ///
    /// Paths are compared component-wise and case-insensitively (default APFS), so `/a/b` is not
    /// inside `/a/bc`. Inputs are expected to be canonical already (scanners build them from canonical
    /// scan dirs); only `.`/`..` are normalized here. The result is sorted by path.
    public static func merge(_ findings: [Finding]) -> [Finding] {
        var byKey: [String: Finding] = [:]
        var components: [String: [String]] = [:]
        for finding in findings {
            let comps = keyComponents(finding.url)
            let key = comps.joined(separator: "/")
            if var existing = byKey[key] {
                existing.sources.formUnion(finding.sources)
                existing.evidence.formUnion(finding.evidence)
                existing.displayName = existing.displayName ?? finding.displayName
                existing.confidence = max(existing.confidence, finding.confidence)
                existing.requiresRoot = existing.requiresRoot || finding.requiresRoot
                existing.inaccessible = existing.inaccessible || finding.inaccessible
                existing.size = maxSize(existing.size, finding.size)
                byKey[key] = existing
            } else {
                byKey[key] = finding
                components[key] = comps
            }
        }

        // Shorter paths first so every ancestor is kept (or absorbed) before its descendants.
        let keys = byKey.keys.sorted { lhs, rhs in
            let lc = components[lhs]!.count
            let rc = components[rhs]!.count
            return lc != rc ? lc < rc : lhs < rhs
        }
        var kept: [String: Finding] = [:]
        for key in keys {
            let finding = byKey[key]!
            let comps = components[key]!
            if let ancestorKey = keptAncestor(of: comps, in: kept) {
                var ancestor = kept[ancestorKey]!
                ancestor.sources.formUnion(finding.sources)
                ancestor.evidence.formUnion(finding.evidence)
                ancestor.requiresRoot = ancestor.requiresRoot || finding.requiresRoot
                ancestor.inaccessible = ancestor.inaccessible || finding.inaccessible
                kept[ancestorKey] = ancestor
            } else {
                kept[key] = finding
            }
        }
        return kept.sorted { $0.key < $1.key }.map(\.value)
    }

    private static func keptAncestor(of comps: [String], in kept: [String: Finding]) -> String? {
        guard comps.count > 1 else { return nil }
        for length in 1..<comps.count {
            let key = comps.prefix(length).joined(separator: "/")
            if kept[key] != nil { return key }
        }
        return nil
    }

    private static func keyComponents(_ url: URL) -> [String] {
        url.standardizedFileURL.path.split(separator: "/").map { $0.lowercased() }
    }

    private static func maxSize(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case (let left?, let right?): return max(left, right)
        case (let left?, nil): return left
        case (nil, let right): return right
        }
    }
}
