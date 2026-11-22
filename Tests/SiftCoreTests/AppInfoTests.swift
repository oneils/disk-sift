import Foundation
import Testing

@testable import SiftCore

@Suite struct AppInfoTests {
    @Test func plainApp() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(bundleID: "com.foo.bar", name: "Bar")
        let info = try AppInfo.load(app)
        #expect(info.bundleID == "com.foo.bar")
        #expect(info.name == "Bar")
        #expect(info.nestedBundleIDs.isEmpty)
    }

    @Test func nameFallsBackToFileName() throws {
        let fx = try Fixture()
        let app = fx.url("Applications/Fallback.app")
        try fx.write("Applications/Fallback.app/Contents/Info.plist", data: plist(["CFBundleIdentifier": "com.foo.fb"]))
        #expect(try AppInfo.load(app).name == "Fallback")
    }

    @Test func displayNameWins() throws {
        let fx = try Fixture()
        let app = fx.url("Applications/X.app")
        try fx.write(
            "Applications/X.app/Contents/Info.plist",
            data: plist(["CFBundleIdentifier": "com.foo.x", "CFBundleName": "Plain", "CFBundleDisplayName": "Fancy"]))
        #expect(try AppInfo.load(app).name == "Fancy")
    }

    @Test func nestedBundleIDsFromHelpersAndExtensions() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(bundleID: "com.foo.bar", name: "Bar", nested: ["com.foo.bar.helper"])
        try fx.write(
            "Applications/Bar.app/Contents/PlugIns/Share.appex/Contents/Info.plist",
            data: plist(["CFBundleIdentifier": "com.foo.bar.share"]))
        try fx.write(
            "Applications/Bar.app/Contents/XPCServices/Svc.xpc/Contents/Info.plist",
            data: plist(["CFBundleIdentifier": "com.foo.bar.svc"]))
        try fx.write(
            "Applications/Bar.app/Contents/Library/LaunchServices/com.foo.bar.priv/Info.plist",
            data: plist(["CFBundleIdentifier": "com.foo.bar.priv"]))
        try fx.write("Applications/Bar.app/Contents/Helpers/tool", "binary")
        let info = try AppInfo.load(app)
        #expect(
            Set(info.nestedBundleIDs) == [
                "com.foo.bar.helper", "com.foo.bar.share", "com.foo.bar.svc", "com.foo.bar.priv",
            ]
        )
    }

    @Test func brokenPlistThrows() throws {
        let fx = try Fixture()
        let app = fx.url("Applications/Broken.app")
        try fx.write("Applications/Broken.app/Contents/Info.plist", "not a plist")
        #expect(throws: ValidationError.unreadableInfoPlist) { try AppInfo.load(app) }
    }

    @Test func missingPlistThrows() throws {
        let fx = try Fixture()
        let app = try fx.mkdir("Applications/Empty.app")
        #expect(throws: ValidationError.unreadableInfoPlist) { try AppInfo.load(app) }
    }

    @Test func missingBundleIDThrows() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(bundleID: nil, name: "NoID")
        #expect(throws: ValidationError.missingBundleID) { try AppInfo.load(app) }
    }

    private func plist(_ dict: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }
}
