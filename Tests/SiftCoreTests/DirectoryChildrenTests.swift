import Foundation
import Testing

@testable import SiftCore

@Suite struct DirectoryChildrenTests {
    private func big(_ kib: Int) -> Data { Data(repeating: 0x41, count: kib * 1024) }

    @Test func listsFilesAndDirsWithSizesLargestFirst() async throws {
        let fx = try Fixture()
        let dir = try fx.mkdir("d")
        try fx.write("d/small.bin", data: big(8))
        try fx.write("d/sub/a.bin", data: big(200))
        try fx.write("d/sub/b.bin", data: big(100))
        try fx.write("d/.hidden", data: big(50))
        let children = try await DirectoryChildren.list(of: dir)
        #expect(children.map(\.url.lastPathComponent) == ["sub", ".hidden", "small.bin"])
        #expect(children[0].kind == .directory)
        #expect(children[1].kind == .file)
        let sub = try await DirectorySizer.size(of: fx.url("d/sub"))
        #expect(children[0].size == sub.bytes)
        #expect(children[0].size >= 300 * 1024)
        #expect(children.allSatisfy { !$0.inaccessible })
    }

    @Test func symlinkIsListedNotFollowed() async throws {
        let fx = try Fixture()
        try fx.write("target/huge.bin", data: big(500))
        let dir = try fx.mkdir("d")
        try fx.symlink("d/link", to: fx.url("target").path)
        let children = try await DirectoryChildren.list(of: dir)
        #expect(children.count == 1)
        #expect(children[0].kind == .symlink)
        #expect(children[0].size < 100 * 1024)
    }

    @Test func unreadableChildIsFlagged() async throws {
        let fx = try Fixture()
        let dir = try fx.mkdir("d")
        try fx.write("d/locked/x.bin", data: big(10))
        try fx.write("d/open.bin", data: big(10))
        try fx.chmod("d/locked", 0)
        let children = try await DirectoryChildren.list(of: dir)
        #expect(children.first { $0.url.lastPathComponent == "locked" }?.inaccessible == true)
        #expect(children.first { $0.url.lastPathComponent == "open.bin" }?.inaccessible == false)
    }

    @Test func emptyAndMissingGiveNothing() async throws {
        let fx = try Fixture()
        let empty = try fx.mkdir("empty")
        #expect(try await DirectoryChildren.list(of: empty).isEmpty)
        #expect(try await DirectoryChildren.list(of: fx.url("nope")).isEmpty)
        let file = try fx.write("f.txt", "x")
        #expect(try await DirectoryChildren.list(of: file).isEmpty)
    }

    @Test func cancelledThrows() async throws {
        let fx = try Fixture()
        let dir = try fx.mkdir("d")
        try fx.write("d/a", "a")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DirectoryChildren.list(of: dir)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
