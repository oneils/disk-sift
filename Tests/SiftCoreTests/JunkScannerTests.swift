import Foundation
import Testing

@testable import SiftCore

struct JunkScannerTests {
    @Test func eventsOrderedPerCategory() async throws {
        let fx = try Fixture()
        try fx.write("home/Library/Caches/com.foo/a", String(repeating: "x", count: 5000))
        try fx.write("home/Library/Developer/Xcode/DerivedData/d", "x")
        let scanner = JunkScanner(paths: fx.paths)
        var events: [JunkProgress] = []
        for await event in scanner.scan() { events.append(event) }
        for id in ["userCaches", "devJunk"] {
            let mine = events.compactMap { event -> String? in
                switch event {
                case .categoryStarted(let c): return c == id ? "start" : nil
                case .findingSized(let c, let f):
                    #expect(f.size != nil)
                    return c == id ? "sized" : nil
                case .categoryFinished(let c): return c == id ? "end" : nil
                case .categoryUnreadable(let c): return c == id ? "unreadable" : nil
                }
            }
            #expect(mine == ["start", "sized", "end"])
        }
    }

    private struct SlowCategory: JunkCategory {
        let id = "slow"
        let title = "Slow"
        let policy = RemovalPolicy.delete
        func scan(paths: SiftPaths) async throws -> [Finding] {
            try await Task.sleep(for: .seconds(30))
            return []
        }
        func checkedByDefault(_ finding: Finding, running: [RunningApp]) -> Bool { true }
    }

    private struct LockedCategory: JunkCategory {
        let id = "locked"
        let title = "Locked"
        let policy = RemovalPolicy.trash
        let expandable = false
        func scan(paths: SiftPaths) async throws -> [Finding] { throw JunkCategoryError.unreadable }
        func checkedByDefault(_ finding: Finding, running: [RunningApp]) -> Bool { false }
    }

    @Test func unreadableCategoryReportedWithoutFinished() async throws {
        let fx = try Fixture()
        let scanner = JunkScanner(categories: [LockedCategory(), DevJunkCategory()], paths: fx.paths)
        var events: [JunkProgress] = []
        for await event in scanner.scan() { events.append(event) }
        let locked = events.compactMap { event -> String? in
            switch event {
            case .categoryStarted("locked"): "start"
            case .categoryUnreadable("locked"): "unreadable"
            case .categoryFinished("locked"): "end"
            default: nil
            }
        }
        #expect(locked == ["start", "unreadable"])
        // the other category still finishes, and so does the stream
        #expect(events.contains { if case .categoryFinished("devJunk") = $0 { true } else { false } })
    }

    @Test func protocolDefaults() {
        #expect(DevJunkCategory().expandable)
        #expect(DevJunkCategory().removalScope == .library)
        #expect(!LockedCategory().expandable)
    }

    @Test func contentsDistinguishesMissingFromUnreadable() throws {
        let fx = try Fixture()
        #expect(try JunkSupport.contents(of: fx.url("home/nope")) == nil)
        let dir = try fx.mkdir("home/Downloads")
        try fx.write("home/Downloads/b")
        try fx.write("home/Downloads/a")
        #expect(try JunkSupport.contents(of: dir) == ["a", "b"])
        try fx.chmod(dir, 0o000)
        #expect(throws: JunkCategoryError.unreadable) { try JunkSupport.contents(of: dir) }
    }

    /// Trashing a directory needs write on the directory itself; deleting doesn't.
    @Test func requiresRootFollowsPolicy() throws {
        let fx = try Fixture()
        let dir = try fx.mkdir("home/Library/Application Support/MobileSync/Backup/abc")
        try fx.chmod(dir, 0o555)
        let trash = JunkSupport.finding(dir, categoryID: "x", policy: .trash, paths: fx.paths)
        let delete = JunkSupport.finding(dir, categoryID: "x", policy: .delete, paths: fx.paths)
        #expect(trash?.requiresRoot == true)
        #expect(delete?.requiresRoot == false)
    }

    @Test func cancellationStopsStream() async throws {
        let fx = try Fixture()
        let scanner = JunkScanner(categories: [SlowCategory()], paths: fx.paths)
        let start = ContinuousClock.now
        let task = Task {
            var count = 0
            for await _ in scanner.scan() {
                count += 1
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return count
        }
        let count = await task.value
        #expect(count == 1)
        #expect(ContinuousClock.now - start < .seconds(10))
    }
}
