import Foundation
import Testing

@testable import SiftCore

@Suite struct LargeFileScannerTests {
    /// Small threshold so real (fully allocated) test files stay small.
    static let minimum: Int64 = 64 * 1024

    private func big(_ fx: Fixture, _ relative: String, kb: Int = 128) throws -> URL {
        try fx.write(relative, data: Data(repeating: 0xAB, count: kb * 1024))
    }

    private func collect(_ fx: Fixture, progressEvery: Int = 500) async -> [LargeFileProgress] {
        var events: [LargeFileProgress] = []
        for await event in LargeFileScanner(paths: fx.paths, minimumSize: Self.minimum, progressEvery: progressEvery)
            .scan()
        {
            events.append(event)
        }
        return events
    }

    private func found(_ events: [LargeFileProgress], _ fx: Fixture) -> Set<String> {
        Set(
            events.compactMap {
                if case .found(let file) = $0 {
                    file.url.path.replacingOccurrences(of: fx.paths.home.path + "/", with: "")
                } else {
                    nil
                }
            })
    }

    @Test func reportsFilesAboveMinimumAndFinishes() async throws {
        let fx = try Fixture()
        try big(fx, "home/Downloads/movie.mkv")
        try big(fx, "home/Movies/deep/a/b/clip.mov", kb: 256)
        try big(fx, "home/.ollama/models/blob")
        try big(fx, "home/Documents/small.txt", kb: 8)
        let events = await collect(fx)
        #expect(found(events, fx) == ["Downloads/movie.mkv", "Movies/deep/a/b/clip.mov", ".ollama/models/blob"])
        #expect(events.last == .finished)
        let clip = events.compactMap {
            if case .found(let f) = $0, f.url.lastPathComponent == "clip.mov" { f } else { nil }
        }
        #expect(clip.first?.size ?? 0 >= 256 * 1024)
        #expect(clip.first?.modified != nil)
    }

    @Test func deniedPlacesAndPackagesAreNotWalked() async throws {
        let fx = try Fixture()
        try big(fx, "home/Library/Caches/huge.bin")
        try big(fx, "home/.Trash/old.dmg")
        try big(fx, "home/Applications/Foo.app/Contents/MacOS/foo")
        try big(fx, "home/Desktop/Bar.app/Contents/Resources/big")
        try big(fx, "home/VMs/Linux.utm/Data/disk.qcow2")
        try big(fx, "home/code/repo/.git/objects/pack/p.pack")
        try big(fx, "home/code/repo/dist.tar")
        let events = await collect(fx)
        #expect(found(events, fx) == ["code/repo/dist.tar"])
    }

    @Test func symlinksNotFollowedAndHardLinksOnce() async throws {
        let fx = try Fixture()
        let target = try big(fx, "tmp/outside.bin")
        try fx.symlink("home/Downloads/link.bin", to: target.path)
        try fx.symlink("home/Downloads/linkdir", to: fx.paths.tmp.path)
        let original = try big(fx, "home/Movies/a.mov")
        try FileManager.default.linkItem(at: original, to: fx.url("home/Movies/b.mov"))
        let events = await collect(fx)
        let names = found(events, fx)
        #expect(names.count == 1)
        #expect(names.isSubset(of: ["Movies/a.mov", "Movies/b.mov"]))
    }

    @Test func unreadableDirectoryReportedAndScanContinues() async throws {
        let fx = try Fixture()
        try big(fx, "home/Private/secret.bin")
        try big(fx, "home/Downloads/ok.bin")
        try fx.chmod("home/Private", 0o000)
        let events = await collect(fx)
        #expect(found(events, fx) == ["Downloads/ok.bin"])
        #expect(
            events.contains {
                if case .unreadable(let url) = $0 { url.path == fx.url("home/Private").path } else { false }
            })
        #expect(events.last == .finished)
    }

    @Test func progressIsThrottled() async throws {
        let fx = try Fixture()
        for i in 0..<10 { try fx.write("home/Documents/f\(i).txt") }
        let events = await collect(fx, progressEvery: 4)
        let progress = events.filter { if case .progress = $0 { true } else { false } }
        #expect(progress.count >= 2)
    }

    @Test func cancellationEndsWithoutFinished() async throws {
        let fx = try Fixture()
        for i in 0..<300 { try fx.write("home/Documents/d\(i % 30)/f\(i).txt") }
        let stream = LargeFileScanner(paths: fx.paths, minimumSize: Self.minimum, progressEvery: 1).scan()
        let task = Task {
            var events: [LargeFileProgress] = []
            for await event in stream {
                events.append(event)
                if events.count == 3 { break }
            }
            return events
        }
        let events = await task.value
        #expect(!events.contains(.finished))
    }

    @Test func largeFileBecomesRemovableFinding() {
        let file = LargeFile(url: URL(fileURLWithPath: "/h/a.bin"), size: 5, modified: nil)
        #expect(file.finding.sources == [.largeFile])
        #expect(file.finding.size == 5)
    }
}
