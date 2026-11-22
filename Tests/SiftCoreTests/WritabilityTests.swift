import Foundation
import Testing

@testable import SiftCore

@Suite struct WritabilityTests {
    @Test func readOnlyFileInWritableDirIsRemovable() throws {
        let fx = try Fixture()
        let file = try fx.write("d/ro.txt", "x")
        try fx.chmod(file, 0o444)
        #expect(Writability.canRemove(file, policy: .delete))
        #expect(Writability.canRemove(file, policy: .trash))
    }

    @Test func readOnlyParentIsNotRemovable() throws {
        let fx = try Fixture()
        let file = try fx.write("d/f.txt", "x")
        try fx.chmod("d", 0o555)
        #expect(!Writability.canRemove(file, policy: .delete))
        #expect(!Writability.canRemove(file, policy: .trash))
    }

    @Test func missingItemIsNotRemovable() throws {
        let fx = try Fixture()
        #expect(!Writability.canRemove(fx.url("nope"), policy: .delete))
    }

    @Test func readOnlyDirectoryNeedsWriteOnlyForTrash() throws {
        let fx = try Fixture()
        let dir = try fx.mkdir("parent/ro")
        try fx.chmod(dir, 0o555)
        #expect(Writability.canRemove(dir, policy: .delete))
        #expect(!Writability.canRemove(dir, policy: .trash))
    }

    @Test func stickyParentRequiresOwnership() throws {
        let fx = try Fixture()
        let mine = try fx.write("sticky/mine.txt", "x")
        try fx.chmod("sticky", 0o1777)
        #expect(Writability.canRemove(mine, policy: .delete))

        // /tmp semantics: sticky and world-writable; find an entry owned by someone else
        guard geteuid() != 0,
            let names = try? FileManager.default.contentsOfDirectory(atPath: "/private/tmp")
        else { return }
        for name in names {
            var st = stat()
            let path = "/private/tmp/\(name)"
            if lstat(path, &st) == 0 && st.st_uid != geteuid() {
                #expect(!Writability.canRemove(URL(fileURLWithPath: path), policy: .delete))
                return
            }
        }
    }
}

@Suite struct DeepWritabilityTests {
    @Test func userTreeCanBeTrashed() throws {
        let fx = try Fixture()
        try fx.write("p/a/b/c.txt", "x")
        try fx.write("p/top.txt", "x")
        #expect(Writability.canTrashDeep(fx.url("p")))
    }

    @Test func plainFileUsesTheShallowRule() throws {
        let fx = try Fixture()
        let file = try fx.write("d/f.txt", "x")
        #expect(Writability.canTrashDeep(file))
        try fx.chmod("d", 0o555)
        #expect(!Writability.canTrashDeep(file))
    }

    @Test func readOnlySubfolderInsideAWritableFolderFails() throws {
        let fx = try Fixture()
        try fx.write("presets/Artists/a.xml", "x")
        try fx.chmod("presets", 0o777)
        try fx.chmod("presets/Artists", 0o555)
        #expect(Writability.canRemove(fx.url("presets"), policy: .trash))
        #expect(!Writability.canTrashDeep(fx.url("presets")))
    }

    @Test func symlinksInsideAreNotFollowed() throws {
        let fx = try Fixture()
        try fx.write("tmp/locked/x", "x")
        try fx.chmod("tmp/locked", 0o555)
        try fx.mkdir("p")
        try fx.symlink("p/link", to: fx.url("tmp/locked").path)
        #expect(Writability.canTrashDeep(fx.url("p")))
    }

    @Test func missingItemFails() throws {
        let fx = try Fixture()
        #expect(!Writability.canTrashDeep(fx.url("nope")))
    }
}
