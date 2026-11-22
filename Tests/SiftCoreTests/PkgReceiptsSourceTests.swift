import Foundation
import Testing

@testable import SiftCore

@Suite struct PkgReceiptsSourceTests {
    private static let pkgutil = "/usr/sbin/pkgutil"

    private func testdata(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("testdata/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func info(_ volume: String, _ location: String) throws -> CommandResult {
        let text = try testdata("pkgutil_info.txt")
            .replacingOccurrences(of: "__VOLUME__", with: volume)
            .replacingOccurrences(of: "__LOCATION__", with: location)
        return CommandResult(stdout: text)
    }

    private func runner(volume: String, location: String, files: String? = nil) throws -> FakeCommandRunner {
        FakeCommandRunner([
            "\(Self.pkgutil) --pkgs": CommandResult(stdout: try testdata("pkgutil_pkgs.txt")),
            "\(Self.pkgutil) --pkg-info com.foo.bar.pkg.app": try info(volume, location),
            "\(Self.pkgutil) --files com.foo.bar.pkg.app": CommandResult(
                stdout: try files ?? testdata("pkgutil_files.txt")),
        ])
    }

    private func app(_ fx: Fixture) -> AppInfo {
        AppInfo(
            url: fx.paths.applications.appendingPathComponent("Bar.app"), bundleID: "com.foo.bar", name: "Bar",
            signing: .unsigned, nestedBundleIDs: [])
    }

    private func relative(_ fx: Fixture, _ found: [Finding]) -> [String] {
        found.map { $0.url.path.replacingOccurrences(of: fx.root.path + "/", with: "") }.sorted()
    }

    @Test func sharedVendorDirIgnoredOwnFilesFound() async throws {
        let fx = try Fixture()
        try fx.write("Library/Application Support/Foo/Shared/common.dat")
        try fx.write("Library/Application Support/Foo/Other/keep.dat")
        try fx.write("Library/Application Support/Foo/Bar/data.bin")
        try fx.write("Library/Logs/Bar.log")
        try fx.write("usr/local/bin/bar-tool")
        let source = PkgReceiptsSource(runner: try runner(volume: fx.root.path, location: ""))
        let found = try await source.findings(for: app(fx), paths: fx.paths)
        #expect(
            relative(fx, found) == [
                "Library/Application Support/Foo/Bar", "Library/Application Support/Foo/Shared",
                "Library/Logs/Bar.log",
            ])
        #expect(
            found.allSatisfy { $0.confidence == .low && $0.sources == [.pkgReceipt] && $0.evidence == [.pkgReceipt] })
    }

    @Test func fullyOwnedVendorDirIsReportedWhole() async throws {
        let fx = try Fixture()
        try fx.write("Library/Application Support/Foo/Shared/common.dat")
        try fx.write("Library/Application Support/Foo/Bar/data.bin")
        let source = PkgReceiptsSource(runner: try runner(volume: fx.root.path, location: ""))
        let found = try await source.findings(for: app(fx), paths: fx.paths)
        #expect(relative(fx, found) == ["Library/Application Support/Foo"])
    }

    @Test func applicationsLocationIsIgnored() async throws {
        let fx = try Fixture()
        try fx.mkdir("Applications/Bar.app/Contents")
        let files = "Bar.app\nBar.app/Contents\n"
        let source = PkgReceiptsSource(runner: try runner(volume: fx.root.path, location: "Applications", files: files))
        #expect(try await source.findings(for: app(fx), paths: fx.paths).isEmpty)
    }

    @Test func locationJoinedWithFiles() async throws {
        let fx = try Fixture()
        try fx.write("Library/Application Support/Foo/Bar/data.bin")
        let files = "Foo\nFoo/Bar\nFoo/Bar/data.bin\n"
        let source = PkgReceiptsSource(
            runner: try runner(volume: fx.root.path, location: "Library/Application Support", files: files))
        let found = try await source.findings(for: app(fx), paths: fx.paths)
        #expect(relative(fx, found) == ["Library/Application Support/Foo"])
    }

    @Test func noMatchingPackage() async throws {
        let fx = try Fixture()
        let other = AppInfo(
            url: fx.paths.applications.appendingPathComponent("X.app"), bundleID: "com.nobody.x", name: "X",
            signing: .unsigned, nestedBundleIDs: [])
        let fake = try runner(volume: fx.root.path, location: "")
        let found = try await PkgReceiptsSource(runner: fake).findings(for: other, paths: fx.paths)
        #expect(found.isEmpty)
        #expect(fake.calls.count == 1)
    }

    @Test func pkgutilFailureGivesEmptyResult() async throws {
        let fx = try Fixture()
        let source = PkgReceiptsSource(runner: FakeCommandRunner())
        #expect(try await source.findings(for: app(fx), paths: fx.paths).isEmpty)
    }
}
