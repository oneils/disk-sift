import Foundation
import Testing

@testable import SiftCore

@Suite struct FullDiskAccessTests {
    @Test func readableTCCDBIsGranted() throws {
        let fx = try Fixture()
        try fx.write("home/Library/Application Support/com.apple.TCC/TCC.db", "x")
        #expect(FullDiskAccess.isGranted(fx.paths))
    }

    @Test func unreadableTCCDBIsDenied() throws {
        let fx = try Fixture()
        try fx.write("home/Library/Application Support/com.apple.TCC/TCC.db", "x")
        try fx.chmod("home/Library/Application Support/com.apple.TCC/TCC.db", 0o000)
        #expect(!FullDiskAccess.isGranted(fx.paths))
    }

    @Test func missingTCCDBIsDenied() throws {
        let fx = try Fixture()
        #expect(!FullDiskAccess.isGranted(fx.paths))
    }
}
