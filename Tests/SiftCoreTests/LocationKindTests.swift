import Foundation
import Testing

@testable import SiftCore

@Suite struct LocationKindTests {
    let paths = SiftPaths(root: URL(fileURLWithPath: "/r"))

    @Test func userAndSystemDirectoriesMapToKinds() {
        let lib = paths.library
        let sys = paths.systemLibrary
        #expect(LocationKind.of(lib.appendingPathComponent("Caches"), paths: paths) == .caches)
        #expect(LocationKind.of(lib.appendingPathComponent("Preferences/ByHost"), paths: paths) == .preferences)
        #expect(LocationKind.of(lib.appendingPathComponent("Group Containers"), paths: paths) == .groupContainers)
        #expect(LocationKind.of(lib.appendingPathComponent("Cookies"), paths: paths) == .webData)
        #expect(LocationKind.of(lib.appendingPathComponent("LaunchAgents"), paths: paths) == .loginServices)
        #expect(LocationKind.of(sys.appendingPathComponent("LaunchDaemons"), paths: paths) == .loginServices)
        #expect(LocationKind.of(sys.appendingPathComponent("Application Support"), paths: paths) == .applicationSupport)
        #expect(LocationKind.of(URL(fileURLWithPath: "/elsewhere"), paths: paths) == .other)
    }

    @Test func caseInsensitiveMatch() {
        #expect(LocationKind.of(URL(fileURLWithPath: "/r/home/library/caches"), paths: paths) == .caches)
    }

    @Test func systemDetection() {
        #expect(LocationKind.isSystem(paths.systemLibrary.appendingPathComponent("Caches"), paths: paths))
        #expect(!LocationKind.isSystem(paths.library.appendingPathComponent("Caches"), paths: paths))
    }

    @Test func displayPathAbbreviatesHome() {
        #expect(paths.displayPath(paths.library.appendingPathComponent("Caches/x")) == "~/Library/Caches/x")
        #expect(paths.displayPath(paths.home) == "~")
        #expect(paths.displayPath(URL(fileURLWithPath: "/r/homework/x")) == "/r/homework/x")
        #expect(paths.displayPath(URL(fileURLWithPath: "/Library/Caches")) == "/Library/Caches")
    }

    @Test func resolverMatchesOfAndNormalizesPaths() {
        let paths = SiftPaths(root: URL(fileURLWithPath: "/r"))
        let resolver = LocationKindResolver(paths: paths)
        let lib = paths.library
        #expect(resolver.kind(of: lib.appendingPathComponent("Caches")) == .caches)
        #expect(resolver.kind(of: URL(fileURLWithPath: lib.path + "/CACHES")) == .caches)
        #expect(resolver.kind(of: URL(fileURLWithPath: lib.path + "/Caches/")) == .caches)
        #expect(resolver.kind(of: URL(fileURLWithPath: lib.path + "/Logs/../Caches")) == .caches)
        #expect(resolver.kind(of: lib.appendingPathComponent("Caches/sub")) == .other)
        for subdir in ScanLocations.userLibrarySubdirs {
            let url = lib.appendingPathComponent(subdir)
            #expect(resolver.kind(of: url) == LocationKind.of(url, paths: paths))
        }
    }
}
