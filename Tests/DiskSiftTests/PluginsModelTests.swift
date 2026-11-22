import Foundation
import SiftCore
import Testing
import os

@testable import DiskSift

private struct FakePluginScanner: PluginScanning {
    let plugins: OSAllocatedUnfairLock<[NeuralDSPPlugin]>
    init(_ plugins: [NeuralDSPPlugin]) { self.plugins = OSAllocatedUnfairLock(initialState: plugins) }
    func scan() async throws -> [NeuralDSPPlugin] { plugins.withLock { $0 } }
}

private final class FakePluginRemover: PluginRemoving, @unchecked Sendable {
    let received = OSAllocatedUnfairLock<[[PluginSelection]]>(initialState: [])
    var result: PluginRemovalResult = .finished(RemovalReport(), [:])
    func remove(_ selections: [PluginSelection]) async -> PluginRemovalResult {
        received.withLock { $0.append(selections) }
        return result
    }
}

@MainActor
@Suite struct PluginsModelTests {
    private func part(
        _ name: String, _ kind: PluginPartKind, size: Int64 = 10, userPresets: Bool = false, admin: Bool = false
    )
        -> PluginPart
    {
        PluginPart(
            kind: kind, url: URL(fileURLWithPath: "/\(kind.rawValue)/\(name)"), size: size,
            containsUserPresets: userPresets, needsAdmin: admin)
    }

    private var nolly: NeuralDSPPlugin {
        NeuralDSPPlugin(
            name: "Nolly",
            parts: [
                part("Nolly", .au, size: 100, admin: true), part("Nolly", .presets, size: 50, userPresets: true),
                part("Nolly", .settings, size: 5),
            ])
    }

    private var gojira: NeuralDSPPlugin { NeuralDSPPlugin(name: "Gojira", parts: [part("Gojira", .manual, size: 7)]) }

    private func model(_ remover: FakePluginRemover = FakePluginRemover()) async -> PluginsModel {
        let m = PluginsModel(scanner: FakePluginScanner([nolly, gojira]), remover: remover, revealer: FakeRevealer())
        await m.scan()
        return m
    }

    @Test func nothingIsSelectedAfterAScan() async {
        let m = await model()
        #expect(m.phase == .ready)
        #expect(m.plugins.map(\.name) == ["Nolly", "Gojira"])
        #expect(m.selections.isEmpty)
        #expect(m.selectedTotal == 0)
    }

    @Test func checkingAPluginSkipsUserPresets() async {
        let m = await model()
        m.setPlugin(m.plugins[0], true)
        #expect(m.state(of: m.plugins[0]) == .mixed)
        #expect(m.selections.first?.kinds == [.au, .settings])
        #expect(m.selectedTotal == 105)
        #expect(m.selectionNeedsAdmin)
        // ticked one by one, user presets can be removed too
        m.setChecked(m.plugins[0].parts[1], true)
        #expect(m.state(of: m.plugins[0]) == .on)
        m.setPlugin(m.plugins[0], false)
        #expect(m.state(of: m.plugins[0]) == .off)
        #expect(m.selections.isEmpty)
    }

    @Test func onlySelectedPartsAreRemoved() async {
        let remover = FakePluginRemover()
        let m = await model(remover)
        m.setChecked(m.plugins[1].parts[0], true)
        #expect(!m.selectionNeedsAdmin)
        m.requestRemove()
        #expect(m.confirming)
        await m.remove()
        let sent = remover.received.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent[0].map(\.plugin.name) == ["Gojira"])
        #expect(sent[0].first?.kinds == [.manual])
    }

    @Test func cancelledPasswordReturnsToTheListWithTheSelection() async {
        let remover = FakePluginRemover()
        remover.result = .cancelled
        let m = await model(remover)
        m.setPlugin(m.plugins[0], true)
        await m.remove()
        #expect(m.phase == .ready)
        #expect(m.selections.first?.kinds == [.au, .settings])
    }

    @Test func reportThenRescan() async {
        let remover = FakePluginRemover()
        let removed = RemovedItem(url: URL(fileURLWithPath: "/manual/Gojira"), size: 7)
        remover.result = .finished(RemovalReport(removed: [removed]), [.trash: [removed]])
        let scanner = FakePluginScanner([nolly, gojira])
        let m = PluginsModel(scanner: scanner, remover: remover, revealer: FakeRevealer())
        await m.scan()
        m.setChecked(m.plugins[1].parts[0], true)
        await m.remove()
        guard case .report(let report) = m.phase else {
            Issue.record("expected report")
            return
        }
        #expect(report.removed == [removed])
        #expect(m.lastRemoved[.trash] == [removed])
        let left = nolly
        scanner.plugins.withLock { $0 = [left] }
        m.closeReport()
        await m.waitForScan()
        #expect(m.plugins.map(\.name) == ["Nolly"])
        #expect(m.selections.isEmpty)
    }

    @Test func nothingSelectedDoesNotConfirm() async {
        let m = await model()
        m.requestRemove()
        #expect(!m.confirming)
    }
}
