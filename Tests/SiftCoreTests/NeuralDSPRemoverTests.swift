import Foundation
import Testing
import os

@testable import SiftCore

/// Acts like the root step in a temp tree: really deletes what it's given (making read-only folders
/// writable first) and forgets nothing (receipts are only recorded).
final class FakePrivilegedRunner: PrivilegedRunner, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [([PrivilegedRemoval], [String])]())
    var outcome: PrivilegedOutcome = .finished
    /// Names left in place although the run "finished" (a failed `rm`).
    var survivors: Set<String> = []

    var calls: [([PrivilegedRemoval], [String])] { state.withLock { $0 } }

    func run(_ removals: [PrivilegedRemoval], forgetting receipts: [String]) async -> PrivilegedOutcome {
        state.withLock { $0.append((removals, receipts)) }
        guard outcome == .finished else { return outcome }
        for removal in removals where !survivors.contains(removal.name) {
            Self.forceRemove("\(removal.parent)/\(removal.name)")
        }
        return outcome
    }

    static func forceRemove(_ path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        chmod(parent, 0o755)
        if let walker = FileManager.default.enumerator(atPath: path) {
            chmod(path, 0o755)
            for case let rel as String in walker { chmod("\(path)/\(rel)", 0o755) }
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}

@Suite struct NeuralDSPRemoverTests {
    private struct Setup {
        let fx: Fixture
        let tree: NeuralDSPTree
        let privileged = FakePrivilegedRunner()
        let trasher = FakeTrasher()
        var running: [RunningApp] = []

        init() throws {
            fx = try Fixture()
            tree = NeuralDSPTree(fx: fx)
        }

        func scan(_ receipts: [String] = []) async throws -> [NeuralDSPPlugin] {
            try await NeuralDSPScanner(
                paths: fx.paths,
                runner: FakeCommandRunner([
                    "/usr/sbin/pkgutil --pkgs": CommandResult(stdout: receipts.joined(separator: "\n"))
                ])
            ).scan()
        }

        func remove(_ selections: [PluginSelection]) async -> PluginRemovalResult {
            await NeuralDSPRemover(
                paths: fx.paths, privileged: privileged, runningApps: FakeRunningApps(apps: running), trasher: trasher,
                runner: FakeCommandRunner()
            ).remove(selections)
        }

        /// Makes a kind's root read-only, like the root-owned 755 plug-in folders.
        func lock(_ kind: PluginPartKind) throws { try fx.chmod(kind.root(fx.paths), 0o555) }
    }

    private func finished(_ result: PluginRemovalResult) -> (RemovalReport, [RemovalPolicy: [RemovedItem]])? {
        if case .finished(let report, let byPolicy) = result { return (report, byPolicy) }
        Issue.record("expected finished, got cancelled")
        return nil
    }

    private func names(_ items: [RemovedItem]?) -> Set<String> { Set((items ?? []).map(\.url.lastPathComponent)) }

    @Test func userWritablePartsGoToTheTrashWithoutAPassword() async throws {
        let s = try Setup()
        try s.tree.part("Archetype Rabea X", .manual)
        try s.tree.part("Archetype Rabea X", .settings)
        let plugin = try #require(try await s.scan().first)
        let result = await s.remove([PluginSelection(plugin: plugin, kinds: [.manual, .settings])])
        let (report, byPolicy) = try #require(finished(result))
        #expect(names(byPolicy[.trash]) == ["Archetype Rabea X"])
        #expect(byPolicy[.trash]?.count == 2)
        #expect(byPolicy[.delete] == nil)
        #expect(report.skipped.isEmpty)
        #expect(s.trasher.trashed.count == 2)
        // nothing root-owned and no receipts: the password prompt never shows
        #expect(s.privileged.calls.count == 1)
        #expect(s.privileged.calls[0].0.isEmpty && s.privileged.calls[0].1.isEmpty)
    }

    @Test func mixedSelectionRunsOneAdminStepThenTrashes() async throws {
        let s = try Setup()
        try s.tree.installAll("Archetype Nolly X")
        try s.lock(.au)
        try s.lock(.vst3)
        let receipts = NeuralDSPTree.receipts("ArchetypeNollyX")
        let plugin = try #require(try await s.scan(receipts).first)
        let result = await s.remove([PluginSelection(plugin: plugin, kinds: [.au, .vst3, .manual, .settings])])
        let (report, byPolicy) = try #require(finished(result))
        #expect(s.privileged.calls.count == 1)
        let (removals, standalone) = s.privileged.calls[0]
        #expect(Set(removals.map(\.name)) == ["Archetype Nolly X.component", "Archetype Nolly X.vst3"])
        #expect(
            Set(removals.compactMap(\.receipt)) == [
                "com.neuraldsp.ArchetypeNollyXAU.pkg", "com.neuraldsp.ArchetypeNollyXVST3.pkg",
            ])
        #expect(removals.allSatisfy { $0.parent.hasPrefix(s.fx.root.path) })
        // the trashed manual's receipt; the settings have none; unselected parts keep theirs
        #expect(standalone == ["com.neuraldsp.ArchetypeNollyXManual.pkg"])
        #expect(names(byPolicy[.delete]) == ["Archetype Nolly X.component", "Archetype Nolly X.vst3"])
        #expect(byPolicy[.trash]?.count == 2)
        #expect(report.skipped.isEmpty)
        // unselected parts are untouched
        for kind in [PluginPartKind.vst, .aax, .app, .presets] {
            #expect(FileManager.default.fileExists(atPath: plugin.parts.first { $0.kind == kind }!.url.path))
        }
    }

    @Test func writableFolderWithAReadOnlyTreeInsideGoesToTheAdminStep() async throws {
        let s = try Setup()
        let presets = try s.tree.part("Archetype Nolly X", .presets)
        try s.fx.write("\(s.tree.rel(.presets))/Archetype Nolly X/Artists/a.xml", "x")
        try s.fx.chmod(presets.appendingPathComponent("Artists"), 0o555)
        let plugin = try #require(try await s.scan().first)
        let (_, byPolicy) = try #require(finished(await s.remove([PluginSelection(plugin: plugin, kinds: [.presets])])))
        #expect(s.privileged.calls.first?.0.map(\.name) == ["Archetype Nolly X"])
        #expect(byPolicy[.delete]?.count == 1)
        #expect(s.trasher.trashed.isEmpty)
    }

    @Test func cancelledPasswordChangesNothing() async throws {
        let s = try Setup()
        try s.tree.part("Archetype Nolly X", .au)
        try s.tree.part("Archetype Nolly X", .settings)
        try s.lock(.au)
        s.privileged.outcome = .cancelled
        let plugin = try #require(try await s.scan().first)
        let result = await s.remove([PluginSelection(plugin: plugin, kinds: [.au, .settings])])
        guard case .cancelled = result else {
            Issue.record("expected cancelled")
            return
        }
        #expect(s.trasher.trashed.isEmpty)
        #expect(plugin.parts.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @Test func failedAdminStepTrashesNothing() async throws {
        let s = try Setup()
        try s.tree.part("Archetype Nolly X", .au)
        try s.tree.part("Archetype Nolly X", .settings)
        try s.lock(.au)
        s.privileged.outcome = .failed("wrong password")
        let plugin = try #require(try await s.scan().first)
        let (report, byPolicy) = try #require(
            finished(await s.remove([PluginSelection(plugin: plugin, kinds: [.au, .settings])])))
        #expect(byPolicy.isEmpty)
        #expect(s.trasher.trashed.isEmpty)
        #expect(report.skipped.map(\.reason) == [.adminStepFailed, .adminStepFailed])
    }

    @Test func survivorsOfAFinishedRunAreReported() async throws {
        let s = try Setup()
        try s.tree.part("Archetype Nolly X", .au)
        try s.tree.part("Archetype Nolly X", .vst)
        try s.lock(.au)
        try s.lock(.vst)
        s.privileged.survivors = ["Archetype Nolly X.vst"]
        let plugin = try #require(try await s.scan().first)
        let (report, byPolicy) = try #require(
            finished(await s.remove([PluginSelection(plugin: plugin, kinds: [.au, .vst])])))
        #expect(names(byPolicy[.delete]) == ["Archetype Nolly X.component"])
        #expect(report.skipped.map(\.url.lastPathComponent) == ["Archetype Nolly X.vst"])
        #expect(report.skipped.first?.reason == .adminStepFailed)
    }

    @Test func runningStandaloneAppSkipsTheWholePlugin() async throws {
        var s = try Setup()
        try s.tree.installAll("Archetype Nolly X")
        let plugin = try #require(try await s.scan().first)
        let app = try #require(plugin.parts.first { $0.kind == .app })
        s.running = [RunningApp(bundleID: "com.neuraldsp.x", bundleURL: app.url, pid: 7)]
        let (report, byPolicy) = try #require(
            finished(await s.remove([PluginSelection(plugin: plugin, kinds: Set(PluginPartKind.allCases))])))
        #expect(byPolicy.isEmpty)
        #expect(report.skipped.count == PluginPartKind.allCases.count)
        #expect(report.skipped.allSatisfy { $0.reason == .inUse })
        #expect(s.privileged.calls.first.map { $0.0.isEmpty && $0.1.isEmpty } == true)
    }

    @Test func partsThatDoNotBelongAreRefused() async throws {
        let s = try Setup()
        try s.tree.part("Archetype Nolly X", .manual)
        let outside = try s.fx.mkdir("tmp/Archetype Nolly X")
        let nested = try s.fx.mkdir("\(s.tree.rel(.manual))/Archetype Nolly X/Archetype Nolly X")
        let wrongExt = try s.fx.mkdir("\(s.tree.rel(.au))/Archetype Nolly X.vst3")
        // a same-named bundle from another vendor in the shared folder
        let foreign = try s.tree.part("Archetype Nolly X", .vst, bundleID: "com.other.vendor")
        let otherName = try s.fx.mkdir("\(s.tree.rel(.manual))/Other")
        try s.fx.write("tmp/real/x", "x")
        let link = try s.fx.symlink("\(s.tree.rel(.settings))/Archetype Nolly X", to: s.fx.url("tmp/real").path)
        let bogus: [PluginPart] = [
            PluginPart(kind: .manual, url: outside, size: 1),
            PluginPart(kind: .manual, url: nested, size: 1),
            PluginPart(kind: .au, url: wrongExt, size: 1),
            PluginPart(kind: .vst, url: foreign, size: 1),
            PluginPart(kind: .manual, url: otherName, size: 1),
            PluginPart(kind: .settings, url: link, size: 1),
            PluginPart(kind: .vst, url: PluginPartKind.vst.root(s.fx.paths), size: 1),
        ]
        let plugin = NeuralDSPPlugin(name: "Archetype Nolly X", parts: bogus)
        let (report, byPolicy) = try #require(
            finished(await s.remove([PluginSelection(plugin: plugin, kinds: Set(PluginPartKind.allCases))])))
        #expect(byPolicy.isEmpty)
        #expect(report.skipped.count == bogus.count)
        #expect(s.trasher.trashed.isEmpty)
        #expect(s.privileged.calls.first?.0.isEmpty == true)
        for part in bogus.dropLast() { #expect(FileManager.default.fileExists(atPath: part.url.path)) }
    }

    @Test func symlinkedKindRootRefusesItsParts() async throws {
        let s = try Setup()
        try s.fx.write("tmp/elsewhere/Archetype Nolly X.vst3/x", "x")
        try s.fx.mkdir("Library/Audio/Plug-Ins")
        try s.fx.symlink("Library/Audio/Plug-Ins/VST3", to: s.fx.url("tmp/elsewhere").path)
        let part = PluginPart(kind: .vst3, url: s.fx.url("Library/Audio/Plug-Ins/VST3/Archetype Nolly X.vst3"), size: 1)
        let plugin = NeuralDSPPlugin(name: "Archetype Nolly X", parts: [part])
        let (report, _) = try #require(finished(await s.remove([PluginSelection(plugin: plugin, kinds: [.vst3])])))
        #expect(report.skipped.map(\.reason) == [.outsideRoots])
        #expect(FileManager.default.fileExists(atPath: s.fx.url("tmp/elsewhere/Archetype Nolly X.vst3").path))
    }

    @Test func receiptsOfAbsentPartsAreForgottenAndOfKeptPartsKept() async throws {
        let s = try Setup()
        try s.tree.part("Archetype Gojira X", .manual)
        try s.tree.part("Archetype Gojira X", .presets)
        let receipts = NeuralDSPTree.receipts("ArchetypeGojiraX", ["AU", "VST3", "Manual", "Presets"])
        let plugin = try #require(try await s.scan(receipts).first)
        _ = try #require(finished(await s.remove([PluginSelection(plugin: plugin, kinds: [.manual])])))
        // AU and VST3 are gone from disk, the manual is trashed; the unselected presets keep their receipt
        #expect(
            Set(s.privileged.calls.first?.1 ?? []) == [
                "com.neuraldsp.ArchetypeGojiraXAU.pkg", "com.neuraldsp.ArchetypeGojiraXVST3.pkg",
                "com.neuraldsp.ArchetypeGojiraXManual.pkg",
            ])
    }
}
