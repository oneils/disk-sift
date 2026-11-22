import Foundation
import Testing

@testable import SiftCore

@Suite struct FindingGroupTests {
    private func finding(_ path: String, size: Int64?) -> Finding {
        Finding(url: URL(fileURLWithPath: path), size: size, confidence: .high, sources: [.libraryPath])
    }

    @Test func emptyInput() {
        #expect(FindingGroup.group([]).isEmpty)
    }

    @Test func groupsByParentSorted() {
        let groups = FindingGroup.group([
            finding("/lib/Prefs/b.plist", size: 1),
            finding("/lib/Caches/z", size: 10),
            finding("/lib/Prefs/a.plist", size: 2),
            finding("/lib/Caches/a", size: 20),
        ])
        #expect(groups.map(\.parent.path) == ["/lib/Caches", "/lib/Prefs"])
        #expect(groups.map(\.id) == ["/lib/Caches", "/lib/Prefs"])
        #expect(groups[0].findings.map(\.url.lastPathComponent) == ["a", "z"])
        #expect(groups[1].findings.map(\.url.lastPathComponent) == ["a.plist", "b.plist"])
        #expect(groups[0].totalSize == 30)
        #expect(groups[1].totalSize == 3)
        #expect(!groups[0].hasUnknownSize)
    }

    @Test func totalsWithNilSizes() {
        let groups = FindingGroup.group([
            finding("/lib/Caches/a", size: nil),
            finding("/lib/Caches/b", size: 5),
            finding("/lib/Logs/x", size: nil),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].totalSize == 5)
        #expect(groups[0].hasUnknownSize)
        #expect(groups[1].totalSize == 0)
        #expect(groups[1].hasUnknownSize)
    }
}
