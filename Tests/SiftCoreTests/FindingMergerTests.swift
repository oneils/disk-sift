import Foundation
import Testing

@testable import SiftCore

@Suite struct FindingMergerTests {
    private func finding(
        _ path: String, size: Int64? = nil, _ confidence: Confidence = .high,
        sources: Set<FindingSource> = [.libraryPath], requiresRoot: Bool = false, inaccessible: Bool = false
    ) -> Finding {
        Finding(
            url: URL(fileURLWithPath: path), size: size, confidence: confidence, sources: sources,
            requiresRoot: requiresRoot, inaccessible: inaccessible)
    }

    @Test func confidenceOrdering() {
        #expect(Confidence.low < .medium)
        #expect(Confidence.medium < .high)
        #expect(!(Confidence.high < .low))
        #expect(Confidence.allCases.max() == .high)
    }

    @Test func emptyInput() {
        #expect(FindingMerger.merge([]).isEmpty)
    }

    @Test func distinctFindingsKeptAndSorted() {
        let merged = FindingMerger.merge([finding("/a/c"), finding("/a/b")])
        #expect(merged.map(\.url.path) == ["/a/b", "/a/c"])
    }

    @Test func duplicatesMerged() throws {
        let merged = FindingMerger.merge([
            finding("/a/b", size: 10, .low, sources: [.libraryPath]),
            finding("/a/b", size: nil, .high, sources: [.pkgReceipt], requiresRoot: true),
            finding("/a/./b", size: 30, .medium, sources: [.groupContainer], inaccessible: true),
        ])
        #expect(merged.count == 1)
        let only = try #require(merged.first)
        #expect(only.confidence == .high)
        #expect(only.sources == [.libraryPath, .pkgReceipt, .groupContainer])
        #expect(only.requiresRoot)
        #expect(only.inaccessible)
        #expect(only.size == 30)
    }

    @Test func duplicatesCompareCaseInsensitively() {
        let merged = FindingMerger.merge([finding("/a/Foo"), finding("/a/foo", sources: [.pkgReceipt])])
        #expect(merged.count == 1)
        #expect(merged.first?.sources == [.libraryPath, .pkgReceipt])
    }

    @Test func nestedChildCollapsedIntoAncestor() {
        let merged = FindingMerger.merge([
            finding("/a/b/c/d", sources: [.pkgReceipt]),
            finding("/a/b", size: 100, sources: [.libraryPath]),
            finding("/a/b/c", size: 50, sources: [.launchItem(label: "x", domain: .user)]),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.url.path == "/a/b")
        #expect(merged.first?.size == 100)
        #expect(merged.first?.sources == [.libraryPath, .pkgReceipt, .launchItem(label: "x", domain: .user)])
    }

    @Test(arguments: [("/a/b", "/a/bc"), ("/a/b", "/a/b.plist"), ("/a/b", "/a/b c")])
    func siblingPrefixNotNested(parent: String, sibling: String) {
        let merged = FindingMerger.merge([finding(parent), finding(sibling)])
        #expect(Set(merged.map(\.url.path)) == [parent, sibling])
    }

    @Test func lowAncestorWithHighChildStaysLow() {
        let merged = FindingMerger.merge([
            finding("/lib/Vendor/App", .high, sources: [.libraryPath]),
            finding("/lib/Vendor", .low, sources: [.pkgReceipt]),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.url.path == "/lib/Vendor")
        #expect(merged.first?.confidence == .low)
        #expect(merged.first?.sources == [.libraryPath, .pkgReceipt])
    }

    @Test func flagsOredFromChild() {
        let merged = FindingMerger.merge([
            finding("/a/b"),
            finding("/a/b/c", requiresRoot: true),
            finding("/a/b/d", inaccessible: true),
            finding("/x/y"),
        ])
        #expect(merged.map(\.url.path) == ["/a/b", "/x/y"])
        #expect(merged[0].requiresRoot)
        #expect(merged[0].inaccessible)
        #expect(!merged[1].requiresRoot)
        #expect(!merged[1].inaccessible)
    }

    @Test func childCaseDifferenceStillNested() {
        let merged = FindingMerger.merge([finding("/A/b"), finding("/a/B/c")])
        #expect(merged.map(\.url.path) == ["/A/b"])
    }
}
