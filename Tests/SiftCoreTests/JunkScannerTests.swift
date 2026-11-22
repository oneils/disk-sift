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

    @Test func cancellationStopsStream() async throws {
        let fx = try Fixture()
        let scanner = JunkScanner(categories: [SlowCategory()], paths: fx.paths)
        let start = ContinuousClock.now
        let task = Task {
            var count = 0
            for await _ in scanner.scan() { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let count = await task.value
        #expect(count == 1)
        #expect(ContinuousClock.now - start < .seconds(10))
    }
}
