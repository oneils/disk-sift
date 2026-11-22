import Foundation
import Testing

@testable import SiftCore

/// Builds Neural DSP install trees under a `Fixture`.
struct NeuralDSPTree {
    let fx: Fixture

    func rel(_ kind: PluginPartKind) -> String {
        kind.root(fx.paths).path.replacingOccurrences(of: fx.root.path + "/", with: "")
    }

    /// Creates the part of `name` of `kind` with one small file inside; returns its URL.
    /// Bundles get an Info.plist with `bundleID` (a Neural DSP one by default).
    @discardableResult
    func part(_ name: String, _ kind: PluginPartKind, bundleID: String? = nil) throws -> URL {
        let entry = kind.pathExtension.map { "\(name).\($0)" } ?? name
        let dir = "\(rel(kind))/\(entry)"
        try fx.write("\(dir)/Contents/data", "x")
        if kind.isBundle {
            let id = bundleID ?? "com.NeuralDSP.\(name.replacingOccurrences(of: " ", with: ""))"
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            try fx.write("\(dir)/Contents/Info.plist", data: data)
        }
        return fx.url(dir)
    }

    func installAll(_ name: String) throws {
        for kind in PluginPartKind.allCases { try part(name, kind) }
    }

    static func receipts(
        _ base: String, _ suffixes: [String] = ["AU", "VST", "VST3", "AAX", "App", "Presets", "Manual"]
    )
        -> [String]
    {
        suffixes.map { "com.neuraldsp.\(base)\($0).pkg" }
    }
}

@Suite struct NeuralDSPScannerTests {
    private func pkgutil(_ ids: [String], status: Int32 = 0) -> FakeCommandRunner {
        FakeCommandRunner([
            "/usr/sbin/pkgutil --pkgs": CommandResult(
                stdout: (ids + ["com.apple.pkg.Core"]).joined(separator: "\n"), status: status)
        ])
    }

    @Test func fullPluginAcrossAllRootsWithReceipts() async throws {
        let fx = try Fixture()
        let tree = NeuralDSPTree(fx: fx)
        try tree.installAll("Archetype Nolly X")
        let receipts = NeuralDSPTree.receipts("ArchetypeNollyX")
        let plugins = try await NeuralDSPScanner(paths: fx.paths, runner: pkgutil(receipts)).scan()
        #expect(plugins.count == 1)
        let plugin = try #require(plugins.first)
        #expect(plugin.name == "Archetype Nolly X")
        #expect(plugin.parts.map(\.kind) == PluginPartKind.allCases)
        #expect(plugin.receipts == receipts.sorted())
        #expect(plugin.hasPluginBundles)
        #expect(plugin.parts.allSatisfy { $0.size > 0 && !$0.needsAdmin })
    }

    @Test func leftoversAndSeparatePlugins() async throws {
        let fx = try Fixture()
        let tree = NeuralDSPTree(fx: fx)
        try tree.part("Archetype Gojira X", .manual)
        try tree.part("Archetype Rabea X", .manual)
        try tree.part("Archetype Rabea X", .settings)
        try tree.part("Morgan Amps Suite", .au)
        let ids =
            NeuralDSPTree.receipts("ArchetypeGojiraX", ["AU", "Manual"])
            + NeuralDSPTree.receipts("MorganAmpsSuite", ["AU"])
        let plugins = try await NeuralDSPScanner(paths: fx.paths, runner: pkgutil(ids)).scan()
        let byName = Dictionary(uniqueKeysWithValues: plugins.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Archetype Gojira X", "Archetype Rabea X", "Morgan Amps Suite"])
        #expect(byName["Archetype Gojira X"]?.parts.map(\.kind) == [.manual])
        #expect(byName["Archetype Gojira X"]?.hasPluginBundles == false)
        #expect(byName["Archetype Gojira X"]?.receipts.count == 2)
        #expect(byName["Archetype Rabea X"]?.parts.map(\.kind) == [.manual, .settings])
        #expect(byName["Archetype Rabea X"]?.receipts.isEmpty == true)
        #expect(byName["Morgan Amps Suite"]?.receipts == ["com.neuraldsp.MorganAmpsSuiteAU.pkg"])
    }

    @Test func entriesThatAreNotPartsAreIgnored() async throws {
        let fx = try Fixture()
        let tree = NeuralDSPTree(fx: fx)
        try fx.write("\(tree.rel(.au))/Other.vst3/x", "x")  // wrong extension for AU
        try fx.write("\(tree.rel(.vst3))/Plain.vst3", "x")  // a file, not a bundle
        try fx.write("\(tree.rel(.presets))/.hidden/x", "x")
        try fx.write("\(tree.rel(.manual))/readme.pdf", "x")  // a file in a folder root
        try fx.write("tmp/real/x", "x")
        try fx.symlink("\(tree.rel(.settings))/Linked", to: fx.url("tmp/real").path)
        let plugins = try await NeuralDSPScanner(paths: fx.paths, runner: pkgutil([])).scan()
        #expect(plugins.isEmpty)
    }

    @Test func otherVendorsBundlesInSharedFoldersAreIgnored() async throws {
        let fx = try Fixture()
        let tree = NeuralDSPTree(fx: fx)
        try tree.part("Kontakt 8", .au, bundleID: "com.native-instruments.kontakt-8.component")
        try tree.part("AppleAES3Audio", .au, bundleID: "com.apple.audio.AES3")
        try fx.write("\(tree.rel(.vst3))/NoPlist.vst3/Contents/x", "x")
        try tree.part("Archetype Nolly X", .vst3)
        let plugins = try await NeuralDSPScanner(paths: fx.paths, runner: pkgutil([])).scan()
        #expect(plugins.map(\.name) == ["Archetype Nolly X"])
    }

    @Test func symlinkedKindRootIsSkipped() async throws {
        let fx = try Fixture()
        try fx.write("tmp/elsewhere/Archetype Nolly X.vst3/x", "x")
        try fx.mkdir("Library/Audio/Plug-Ins")
        try fx.symlink("Library/Audio/Plug-Ins/VST3", to: fx.url("tmp/elsewhere").path)
        #expect(try await NeuralDSPScanner(paths: fx.paths, runner: pkgutil([])).scan().isEmpty)
    }

    @Test func userPresetsAndAdminFlag() async throws {
        let fx = try Fixture()
        let tree = NeuralDSPTree(fx: fx)
        let presets = try tree.part("Archetype Nolly X", .presets)
        try fx.write("\(tree.rel(.presets))/Archetype Nolly X/User/My Tone.xml", "x")
        try fx.write("\(tree.rel(.presets))/Archetype Nolly X/Artists/a.xml", "x")
        try fx.chmod(presets.appendingPathComponent("Artists"), 0o555)
        try tree.part("Archetype Plini X", .presets)
        try fx.mkdir("\(tree.rel(.presets))/Archetype Plini X/User")
        try fx.write("\(tree.rel(.presets))/Archetype Plini X/User/.DS_Store", "x")
        let plugins = try await NeuralDSPScanner(paths: fx.paths, runner: pkgutil([])).scan()
        let nolly = try #require(plugins.first { $0.name == "Archetype Nolly X" }?.parts.first)
        #expect(nolly.containsUserPresets)
        #expect(nolly.needsAdmin)
        let plini = try #require(plugins.first { $0.name == "Archetype Plini X" }?.parts.first)
        #expect(!plini.containsUserPresets)
        #expect(!plini.needsAdmin)
    }

    @Test func pkgutilFailureGivesNoReceipts() async throws {
        let fx = try Fixture()
        try NeuralDSPTree(fx: fx).part("Archetype Nolly X", .au)
        let plugins = try await NeuralDSPScanner(
            paths: fx.paths, runner: pkgutil(NeuralDSPTree.receipts("ArchetypeNollyX"), status: 1)
        ).scan()
        #expect(plugins.first?.receipts.isEmpty == true)
    }

    @Test func largestFirst() async throws {
        let fx = try Fixture()
        let tree = NeuralDSPTree(fx: fx)
        try tree.part("Small", .manual)
        try tree.part("Big", .manual)
        try fx.write("\(tree.rel(.manual))/Big/big.bin", String(repeating: "x", count: 200_000))
        let plugins = try await NeuralDSPScanner(paths: fx.paths, runner: pkgutil([])).scan()
        #expect(plugins.map(\.name) == ["Big", "Small"])
    }
}
