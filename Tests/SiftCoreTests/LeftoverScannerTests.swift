import Foundation
import Testing

@testable import SiftCore

private struct StaticSource: LeftoverSource {
    var result: [Finding]

    func findings(for app: AppInfo, paths: SiftPaths) async throws -> [Finding] { result }
}

private struct FailingSource: LeftoverSource {
    func findings(for app: AppInfo, paths: SiftPaths) async throws -> [Finding] {
        throw SiftError.commandLaunchFailed(executable: "x", reason: "boom")
    }
}

private struct SlowSource: LeftoverSource {
    func findings(for app: AppInfo, paths: SiftPaths) async throws -> [Finding] {
        try await Task.sleep(for: .seconds(30))
        return []
    }
}

@Suite struct LeftoverScannerTests {
    private func app(_ fx: Fixture) -> AppInfo {
        AppInfo(
            url: fx.paths.applications.appendingPathComponent("Bar.app"), bundleID: "com.foo.bar", name: "Barista",
            signing: .unsigned, nestedBundleIDs: [])
    }

    @Test func endToEndAcrossDirs() async throws {
        let fx = try Fixture()
        try fx.write("home/Library/Caches/com.foo.bar/data.bin", String(repeating: "x", count: 10_000))
        try fx.write("home/Library/Preferences/com.foo.bar.plist", "p")
        try fx.write("home/Library/Application Support/Barista/x", "y")
        let scanner = LeftoverScanner(
            sources: [LibraryPathsSource(installed: FakeInstalledApps(), hasFullDiskAccess: { _ in true })],
            paths: fx.paths)
        let found = try await scanner.scan(app(fx))
        let names = Set(found.map { $0.url.lastPathComponent })
        #expect(names == ["com.foo.bar", "com.foo.bar.plist", "Barista"])
        #expect(found.allSatisfy { ($0.size ?? 0) > 0 })
        let cache = try #require(found.first { $0.url.lastPathComponent == "com.foo.bar" })
        #expect(cache.confidence == .high)
        #expect(LeftoverScanner.defaultChecked(cache))
        let support = try #require(found.first { $0.url.lastPathComponent == "Barista" })
        #expect(!LeftoverScanner.defaultChecked(support))
    }

    @Test func failingSourceDoesNotFailScan() async throws {
        let fx = try Fixture()
        let file = try fx.write("home/Library/Caches/a", "abc")
        let good = Finding(url: file, confidence: .high, sources: [.libraryPath])
        let scanner = LeftoverScanner(sources: [FailingSource(), StaticSource(result: [good])], paths: fx.paths)
        let found = try await scanner.scan(app(fx))
        #expect(found.map(\.url) == [file])
    }

    @Test func cancellationPropagates() async throws {
        let fx = try Fixture()
        let scanner = LeftoverScanner(sources: [SlowSource()], paths: fx.paths)
        let info = app(fx)
        let task = Task { try await scanner.scan(info) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func defaultChecks() {
        func finding(_ confidence: Confidence, root: Bool) -> Finding {
            Finding(url: URL(fileURLWithPath: "/x"), confidence: confidence, sources: [], requiresRoot: root)
        }
        #expect(LeftoverScanner.defaultChecked(finding(.high, root: false)))
        #expect(!LeftoverScanner.defaultChecked(finding(.high, root: true)))
        #expect(!LeftoverScanner.defaultChecked(finding(.medium, root: false)))
        #expect(!LeftoverScanner.defaultChecked(finding(.low, root: false)))
    }
}
