import Foundation
import Testing

@testable import SiftCore

@Suite struct NeuralDSPLocationsTests {
    @Test func rootsFollowSiftPaths() throws {
        let fx = try Fixture()
        let rel = { (kind: PluginPartKind) in
            kind.root(fx.paths).path.replacingOccurrences(of: fx.root.path + "/", with: "")
        }
        #expect(rel(.au) == "Library/Audio/Plug-Ins/Components")
        #expect(rel(.vst) == "Library/Audio/Plug-Ins/VST")
        #expect(rel(.vst3) == "Library/Audio/Plug-Ins/VST3")
        #expect(rel(.aax) == "Library/Application Support/Avid/Audio/Plug-Ins")
        #expect(rel(.app) == "Applications/Neural DSP")
        #expect(rel(.presets) == "Library/Audio/Presets/Neural DSP")
        #expect(rel(.manual) == "Library/Application Support/Neural DSP")
        #expect(rel(.settings) == "home/Library/Application Support/Neural DSP")
    }

    @Test(arguments: [
        ("Archetype Nolly X.component", PluginPartKind.au, "Archetype Nolly X"),
        ("Archetype Nolly X.vst", .vst, "Archetype Nolly X"),
        ("Archetype Nolly X.vst3", .vst3, "Archetype Nolly X"),
        ("Archetype Nolly X.aaxplugin", .aax, "Archetype Nolly X"),
        ("Morgan Amps Suite.app", .app, "Morgan Amps Suite"),
        ("Morgan Amps Suite", .presets, "Morgan Amps Suite"),
        ("Archetype Gojira X", .manual, "Archetype Gojira X"),
        ("Archetype Rabea X", .settings, "Archetype Rabea X"),
    ])
    func partNames(entry: String, kind: PluginPartKind, expected: String) {
        #expect(NeuralDSPLocations.partName(of: entry, kind: kind) == expected)
    }

    @Test func entriesThatDoNotBelongAreRejected() {
        #expect(NeuralDSPLocations.partName(of: "Foo.vst3", kind: .vst) == nil)
        #expect(NeuralDSPLocations.partName(of: "Foo.vst", kind: .vst3) == nil)
        #expect(NeuralDSPLocations.partName(of: "Foo", kind: .au) == nil)
        #expect(NeuralDSPLocations.partName(of: ".component", kind: .au) == nil)
        #expect(NeuralDSPLocations.partName(of: ".DS_Store", kind: .presets) == nil)
    }

    @Test func receiptsMatchEveryKindOfThatPlugin() {
        let expected: [(String, PluginPartKind)] = [
            ("AU", .au), ("VST", .vst), ("VST3", .vst3), ("AAX", .aax), ("App", .app), ("Presets", .presets),
            ("Manual", .manual),
        ]
        for (suffix, kind) in expected {
            #expect(
                NeuralDSPLocations.receiptKind("com.neuraldsp.ArchetypeNollyX\(suffix).pkg", of: "Archetype Nolly X")
                    == kind)
        }
    }

    @Test(arguments: [
        "com.neuraldsp.ArchetypeNollyXIIAU.pkg", "com.neuraldsp.ArchetypePliniXAU.pkg",
        "com.other.ArchetypeNollyXAU.pkg", "com.neuraldsp.ArchetypeNollyXAU", "com.neuraldsp.ArchetypeNollyXFoo.pkg",
        "xcom.neuraldsp.ArchetypeNollyXAU.pkg", "com.neuraldsp.ArchetypeNollyXAU.pkg.extra",
    ])
    func otherReceiptsAreRejected(receipt: String) {
        #expect(NeuralDSPLocations.receiptKind(receipt, of: "Archetype Nolly X") == nil)
    }

    @Test func regexCharactersInNamesAreLiteral() {
        #expect(NeuralDSPLocations.receiptKind("com.neuraldsp.A.BAU.pkg", of: "A.B") == .au)
        #expect(NeuralDSPLocations.receiptKind("com.neuraldsp.AxBAU.pkg", of: "A.B") == nil)
    }

    @Test func canonicalRootRefusesSymlinksAndMissingFolders() throws {
        let fx = try Fixture()
        #expect(PluginPartKind.au.canonicalRoot(fx.paths) == nil)
        try fx.mkdir("Library/Audio/Plug-Ins/Components")
        let auRoot = PluginPartKind.au.canonicalRoot(fx.paths)
        #expect(auRoot?.path == fx.url("Library/Audio/Plug-Ins/Components").path, "\(String(describing: auRoot))")
        try fx.mkdir("tmp/elsewhere")
        try fx.mkdir("Library/Audio/Plug-Ins")
        try fx.symlink("Library/Audio/Plug-Ins/VST3", to: fx.url("tmp/elsewhere").path)
        #expect(PluginPartKind.vst3.canonicalRoot(fx.paths) == nil)
        // a symlinked parent of the root resolves elsewhere: refused too
        try fx.mkdir("tmp/presets/Neural DSP")
        try fx.mkdir("Library/Audio")
        try fx.symlink("Library/Audio/Presets", to: fx.url("tmp/presets").path)
        #expect(PluginPartKind.presets.canonicalRoot(fx.paths) == nil)
    }

    @Test func pluginTotalsAndLeftovers() {
        let manual = PluginPart(kind: .manual, url: URL(fileURLWithPath: "/m"), size: 10)
        let au = PluginPart(kind: .au, url: URL(fileURLWithPath: "/a"), size: 5)
        #expect(!NeuralDSPPlugin(name: "X", parts: [manual]).hasPluginBundles)
        let full = NeuralDSPPlugin(name: "X", parts: [au, manual])
        #expect(full.hasPluginBundles)
        #expect(full.totalSize == 15)
    }
}
