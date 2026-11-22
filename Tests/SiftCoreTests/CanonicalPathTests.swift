import Foundation
import Testing

@testable import SiftCore

@Suite struct CanonicalPathTests {
    @Test func resolvesVarToPrivateVar() throws {
        let canonical = try CanonicalPath.of(URL(fileURLWithPath: "/var/tmp/x"))
        #expect(canonical.path.hasPrefix("/private/var/tmp") || canonical.path == "/var/tmp/x")
        let real = try CanonicalPath.of(URL(fileURLWithPath: "/private/var/tmp/x"))
        #expect(canonical == real)
    }

    @Test func symlinkedMiddleDirIsResolved() throws {
        let fx = try Fixture()
        try fx.mkdir("outside/sub")
        try fx.mkdir("inside")
        try fx.symlink("inside/link", to: fx.url("outside").path)
        let canonical = try CanonicalPath.of(fx.url("inside/link/sub"))
        #expect(canonical.path == fx.url("outside/sub").path)
        let inside = try CanonicalPath.of(fx.url("inside"))
        #expect(!canonical.isStrictlyInside(inside))
    }

    @Test func symlinkAsLastComponentStaysLink() throws {
        let fx = try Fixture()
        try fx.mkdir("target")
        try fx.symlink("link", to: fx.url("target").path)
        let canonical = try CanonicalPath.of(fx.url("link"))
        #expect(canonical.path == fx.url("link").path)
    }

    @Test func missingParentThrows() throws {
        let fx = try Fixture()
        #expect(throws: (any Error).self) { try CanonicalPath.of(fx.url("nope/child")) }
    }

    @Test func strictlyInsideIsComponentWiseAndCaseInsensitive() {
        let root = CanonicalPath(path: "/a/Bb")
        #expect(CanonicalPath(path: "/a/bb/c").isStrictlyInside(root))
        #expect(CanonicalPath(path: "/A/BB/c/d").isStrictlyInside(root))
        #expect(!CanonicalPath(path: "/a/bbc").isStrictlyInside(root))
        #expect(!CanonicalPath(path: "/a/bb").isStrictlyInside(root))
        #expect(!CanonicalPath(path: "/a").isStrictlyInside(root))
    }
}
