import Foundation
import Security
import Testing

@testable import SiftCore

@Suite struct SigningInfoTests {
    @Test func parsesTeamIDAndAppGroups() {
        let dict: [String: Any] = [
            kSecCodeInfoTeamIdentifier as String: "ABCDE12345",
            kSecCodeInfoEntitlementsDict as String: [
                "com.apple.security.application-groups": ["ABCDE12345.shared", "group.com.foo"]
            ],
        ]
        let info = SigningInfo.parse(dict)
        #expect(info.teamID == "ABCDE12345")
        #expect(info.appGroups == ["ABCDE12345.shared", "group.com.foo"])
        #expect(!info.isAppleAnchored)
    }

    @Test func noEntitlements() {
        let info = SigningInfo.parse([kSecCodeInfoTeamIdentifier as String: "ABCDE12345"])
        #expect(info == SigningInfo(teamID: "ABCDE12345", appGroups: []))
    }

    @Test func unsignedIsEmpty() {
        #expect(SigningInfo.parse([:]) == .unsigned)
    }

    @Test func readOfUnsignedBundleIsEmpty() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(bundleID: "com.foo.bar", name: "Bar")
        #expect(SigningInfo.read(app) == .unsigned)
    }

    @Test func readOfMissingPathIsEmpty() throws {
        let fx = try Fixture()
        #expect(SigningInfo.read(fx.url("Missing.app")) == .unsigned)
    }
}
