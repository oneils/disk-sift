import Foundation
import Testing

@testable import SiftCore

@Suite struct DirectorySizerTests {
    private func du(_ url: URL) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return Int64(text.split(whereSeparator: \.isWhitespace).first ?? "") ?? -1
    }

    private func bigData(_ kib: Int) -> Data {
        Data(repeating: 0x41, count: kib * 1024)
    }

    @Test func matchesDuOnTree() async throws {
        let fx = try Fixture()
        let root = try fx.mkdir("tree")
        for i in 0..<20 {
            try fx.write("tree/d\(i % 4)/f\(i).bin", data: bigData(i * 3 + 1))
        }
        try fx.write("tree/top.txt", "hello")
        let result = try await DirectorySizer.size(of: root)
        #expect(result.bytes / 1024 == (try du(root)))
        #expect(!result.inaccessible)
    }

    @Test func singleFile() async throws {
        let fx = try Fixture()
        let file = try fx.write("f.bin", data: bigData(100))
        let result = try await DirectorySizer.size(of: file)
        #expect(result.bytes / 1024 == (try du(file)))
        #expect(result.bytes >= 100 * 1024)
    }

    @Test func emptyDir() async throws {
        let fx = try Fixture()
        let dir = try fx.mkdir("empty")
        let result = try await DirectorySizer.size(of: dir)
        #expect(result.bytes / 1024 == (try du(dir)))
        #expect(!result.inaccessible)
    }

    @Test func missingPathIsZero() async throws {
        let fx = try Fixture()
        let result = try await DirectorySizer.size(of: fx.url("nope"))
        #expect(result == SizeResult(bytes: 0))
    }

    @Test func symlinkToBigFileIsNotCounted() async throws {
        let fx = try Fixture()
        let big = try fx.write("outside/big.bin", data: bigData(2048))
        let dir = try fx.mkdir("dir")
        try fx.symlink("dir/link", to: big.path)
        let result = try await DirectorySizer.size(of: dir)
        #expect(result.bytes < 1024 * 1024)
    }

    @Test func hardLinksAcrossChildrenCountedOnce() async throws {
        let fx = try Fixture()
        let original = try fx.write("dir/a/big.bin", data: bigData(1024))
        try fx.mkdir("dir/b")
        try FileManager.default.linkItem(at: original, to: fx.url("dir/b/big-link.bin"))
        let result = try await DirectorySizer.size(of: fx.url("dir"))
        #expect(result.bytes >= 1024 * 1024)
        #expect(result.bytes < 2 * 1024 * 1024)
    }

    @Test func cancellationStopsEarly() async throws {
        let fx = try Fixture()
        for i in 0..<3000 {
            try fx.write("tree/d\(i % 10)/f\(i).txt", "x")
        }
        let root = fx.url("tree")
        let task = Task { try await DirectorySizer.size(of: root) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func unreadableSubdirIsInaccessibleWithPartialSize() async throws {
        let fx = try Fixture()
        try fx.write("tree/ok/f.bin", data: bigData(64))
        try fx.write("tree/locked/f.bin", data: bigData(64))
        try fx.chmod("tree/locked", 0o000)
        let result = try await DirectorySizer.size(of: fx.url("tree"))
        #expect(result.inaccessible)
        #expect(result.bytes >= 64 * 1024)
        #expect(result.bytes < 128 * 1024 + 64 * 1024)
    }
}
