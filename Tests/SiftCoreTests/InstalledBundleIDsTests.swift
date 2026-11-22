import Foundation
import Testing

@testable import SiftCore

@Suite struct InstalledBundleIDsTests {
    private func bundle(_ fx: Fixture, _ relative: String, id: String?, flat: Bool = false) throws {
        var dict: [String: Any] = ["CFBundleName": "X"]
        if let id { dict["CFBundleIdentifier"] = id }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try fx.write("\(relative)/\(flat ? "" : "Contents/")Info.plist", data: data)
    }

    @Test func appsAtTopLevelAndInASubfolder() throws {
        let fx = try Fixture()
        try bundle(fx, "Applications/Foo.app", id: "com.Foo.App")
        try bundle(fx, "Applications/Utilities/Tool.app", id: "com.tool.app")
        try bundle(fx, "home/Applications/Mine.app", id: "org.me.mine")
        #expect(InstalledBundleIDs.collect(paths: fx.paths) == ["com.foo.app", "com.tool.app", "org.me.mine"])
    }

    @Test func deeplyNestedBundlesAreIncluded() throws {
        let fx = try Fixture()
        let app = "Applications/Big.app"
        try bundle(fx, app, id: "com.big.app")
        try bundle(
            fx, "\(app)/Contents/Frameworks/Electron Framework.framework/Versions/A/Helpers/Big Helper.app",
            id: "com.big.app.helper")
        try bundle(
            fx, "\(app)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc",
            id: "org.sparkle-project.InstallerLauncher")
        try bundle(
            fx, "\(app)/Contents/Library/SystemExtensions/net.vendor.filter.systemextension", id: "net.vendor.filter")
        try bundle(fx, "\(app)/Contents/PlugIns/Share.appex", id: "com.big.share")
        try bundle(fx, "\(app)/Contents/PlugIns/Share.appex/Contents/PlugIns/Inner.appex", id: "io.other.inner")
        try bundle(fx, "\(app)/Contents/Library/QuickLook/Preview.qlgenerator", id: "com.big.ql")
        let ids = InstalledBundleIDs.collect(paths: fx.paths)
        #expect(
            ids == [
                "com.big.app", "com.big.app.helper", "org.sparkle-project.installerlauncher", "net.vendor.filter",
                "com.big.share", "io.other.inner", "com.big.ql",
            ])
    }

    @Test func brokenBundlesSkipped() throws {
        let fx = try Fixture()
        try bundle(fx, "Applications/NoID.app", id: nil)
        try fx.write("Applications/Broken.app/Contents/Info.plist", "not a plist")
        try bundle(fx, "Applications/Good.app", id: "com.good.app")
        #expect(InstalledBundleIDs.collect(paths: fx.paths) == ["com.good.app"])
    }

    @Test func symlinksInsideBundlesNotFollowed() throws {
        let fx = try Fixture()
        try bundle(fx, "Applications/A.app", id: "com.a.app")
        try bundle(fx, "tmp/Elsewhere/Outside.bundle", id: "com.outside")
        try fx.symlink("Applications/A.app/Contents/Frameworks/Link", to: fx.url("tmp/Elsewhere").path)
        #expect(InstalledBundleIDs.collect(paths: fx.paths) == ["com.a.app"])
    }

    @Test func symlinkedAppAtTopLevelCounts() throws {
        let fx = try Fixture()
        try bundle(fx, "tmp/Real.app", id: "com.real.app")
        try fx.symlink("Applications/Real.app", to: fx.url("tmp/Real.app").path)
        #expect(InstalledBundleIDs.collect(paths: fx.paths) == ["com.real.app"])
    }

    @Test func missingFoldersGiveNothing() throws {
        let fx = try Fixture()
        try FileManager.default.removeItem(at: fx.paths.applications)
        #expect(InstalledBundleIDs.collect(paths: fx.paths).isEmpty)
    }

    @Test func trashCheck() {
        let home = URL(fileURLWithPath: "/Users/u")
        #expect(TrashCheck.isInTrash(URL(fileURLWithPath: "/Users/u/.Trash/Foo.app"), home: home))
        #expect(TrashCheck.isInTrash(URL(fileURLWithPath: "/Volumes/X/.Trashes/501/Foo.app"), home: home))
        #expect(!TrashCheck.isInTrash(URL(fileURLWithPath: "/Applications/Foo.app"), home: home))
        #expect(!TrashCheck.isInTrash(URL(fileURLWithPath: "/Users/u/.Trashy/Foo.app"), home: home))
    }
}
