import Foundation
import Testing

@testable import SiftCore

@Suite struct AppValidatorTests {
    private func validator(_ fx: Fixture, apple: Bool = false) -> AppValidator {
        AppValidator(paths: fx.paths) { _ in SigningInfo(isAppleAnchored: apple) }
    }

    @Test func acceptsPlainApp() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(bundleID: "com.foo.bar", name: "Bar")
        let info = try validator(fx).validate(app)
        #expect(info.bundleID == "com.foo.bar")
    }

    @Test func acceptsUserApplications() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(bundleID: "com.foo.bar", name: "Bar", in: fx.paths.userApplications)
        #expect(try validator(fx).validate(app).name == "Bar")
    }

    @Test func rejectsNotAnApp() throws {
        let fx = try Fixture()
        let dir = try fx.mkdir("Applications/Folder")
        #expect(throws: ValidationError.notAnApp) { try validator(fx).validate(dir) }
    }

    @Test func rejectsMissing() throws {
        let fx = try Fixture()
        #expect(throws: ValidationError.notFound) { try validator(fx).validate(fx.url("Applications/Gone.app")) }
    }

    @Test func rejectsSymlinkedApp() throws {
        let fx = try Fixture()
        let real = try fx.makeApp(bundleID: "com.foo.bar", name: "Bar", in: fx.paths.tmp)
        let link = try fx.symlink("Applications/Link.app", to: real.path)
        #expect(throws: ValidationError.symlink) { try validator(fx).validate(link) }
    }

    @Test func rejectsAppNestedInBundle() throws {
        let fx = try Fixture()
        try fx.makeApp(bundleID: "com.foo.outer", name: "Outer")
        let inner = fx.url("Applications/Outer.app/Contents/Applications/Inner.app")
        try fx.write("Applications/Outer.app/Contents/Applications/Inner.app/Contents/Info.plist")
        #expect(throws: ValidationError.nestedInBundle) { try validator(fx).validate(inner) }
    }

    @Test func rejectsOutsideApplications() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(bundleID: "com.foo.bar", name: "Bar", in: fx.paths.tmp)
        #expect(throws: ValidationError.outsideApplications) { try validator(fx).validate(app) }
        let calc = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        #expect(throws: ValidationError.outsideApplications) { try validator(fx).validate(calc) }
    }

    @Test func rejectsVolumes() throws {
        let fx = try Fixture()
        let app = URL(fileURLWithPath: "/Volumes/External/Foo.app")
        #expect(throws: ValidationError.onVolume) { try validator(fx).validate(app) }
    }

    @Test func rejectsTranslocation() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(bundleID: "com.foo.bar", name: "Bar", in: fx.mkdir("Applications/AppTranslocation/X"))
        #expect(throws: ValidationError.translocated) { try validator(fx).validate(app) }
    }

    @Test func rejectsSelfAndMissingBundleID() throws {
        let fx = try Fixture()
        let me = try fx.makeApp(bundleID: AppValidator.selfBundleID, name: "DiskSift")
        #expect(throws: ValidationError.isSelf) { try validator(fx).validate(me) }
        let noID = try fx.makeApp(bundleID: nil, name: "NoID")
        #expect(throws: ValidationError.missingBundleID) { try validator(fx).validate(noID) }
    }

    @Test func rejectsAppleApp() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(bundleID: "com.apple.foo", name: "Foo")
        #expect(throws: ValidationError.appleApp) { try validator(fx, apple: true).validate(app) }
    }

    @Test func rejectsRealSafari() throws {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        guard FileManager.default.fileExists(atPath: safari.path) else { return }
        #expect(throws: ValidationError.self) { try AppValidator(paths: .live).validate(safari) }
    }

    @Test func readOnlyAppIsNotRemovable() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(bundleID: "com.foo.bar", name: "Bar")
        try fx.chmod(app, 0o555)
        #expect(throws: ValidationError.notRemovable) { try validator(fx).validate(app) }
    }
}
