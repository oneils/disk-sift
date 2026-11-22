import Foundation
import SiftCore

protocol PluginScanning: Sendable {
    func scan() async throws -> [NeuralDSPPlugin]
}

protocol PluginRemoving: Sendable {
    func remove(_ selections: [PluginSelection]) async -> PluginRemovalResult
}

extension NeuralDSPScanner: PluginScanning {}
extension NeuralDSPRemover: PluginRemoving {}

/// Neural DSP plugins: scan, pick plugins or single parts (nothing preselected), remove after one
/// administrator password prompt for the root-owned parts.
@Observable
@MainActor
final class PluginsModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case removing
        case report(RemovalReport)
    }

    private(set) var phase: Phase = .idle
    /// Largest first.
    private(set) var plugins: [NeuralDSPPlugin] = []
    /// Checked part IDs (paths).
    private(set) var checked: Set<String> = []
    var expanded: Set<String> = []
    var confirming = false
    /// What the last removal did per policy, for the report.
    private(set) var lastRemoved: [RemovalPolicy: [RemovedItem]] = [:]
    /// Set when "Show in Finder" hit an item that no longer exists.
    var missingItem: URL?
    let paths: SiftPaths

    private let scanner: any PluginScanning
    private let remover: any PluginRemoving
    private let revealer: any FileRevealing
    private var scanTask: Task<Void, Never>?

    init(
        scanner: any PluginScanning, remover: any PluginRemoving, revealer: any FileRevealing = LiveFileRevealer(),
        paths: SiftPaths = .live
    ) {
        self.scanner = scanner
        self.remover = remover
        self.revealer = revealer
        self.paths = paths
    }

    static func live(paths: SiftPaths = .live) -> PluginsModel {
        PluginsModel(
            scanner: NeuralDSPScanner(paths: paths),
            remover: NeuralDSPRemover(
                paths: paths, privileged: OSAScriptPrivilegedRunner(), runningApps: LiveRunningApps()),
            paths: paths)
    }

    // MARK: scan

    func startScan() {
        guard phase == .idle || phase == .ready else { return }
        scanTask = Task { await scan() }
    }

    func waitForScan() async {
        await scanTask?.value
    }

    func scan() async {
        guard phase == .idle || phase == .ready else { return }
        phase = .scanning
        do {
            plugins = try await scanner.scan()
        } catch {
            plugins = []
        }
        let ids = Set(plugins.flatMap(\.parts).map(\.id))
        checked.formIntersection(ids)
        phase = .ready
    }

    var hasScanned: Bool { phase != .idle }

    var foundNothing: Bool { phase == .ready && plugins.isEmpty }

    // MARK: selection

    func isChecked(_ part: PluginPart) -> Bool { checked.contains(part.id) }

    func setChecked(_ part: PluginPart, _ on: Bool) {
        guard phase == .ready else { return }
        if on { checked.insert(part.id) } else { checked.remove(part.id) }
    }

    /// Checking a plugin selects every part except presets holding the user's own presets; those are
    /// only removed when ticked one by one.
    func setPlugin(_ plugin: NeuralDSPPlugin, _ on: Bool) {
        for part in plugin.parts where !on || !part.containsUserPresets { setChecked(part, on) }
    }

    func state(of plugin: NeuralDSPPlugin) -> JunkModel.CheckState {
        let on = plugin.parts.filter { checked.contains($0.id) }.count
        if on == 0 { return .off }
        return on == plugin.parts.count ? .on : .mixed
    }

    var selections: [PluginSelection] {
        plugins.compactMap { plugin in
            let kinds = Set(plugin.parts.filter { checked.contains($0.id) }.map(\.kind))
            return kinds.isEmpty ? nil : PluginSelection(plugin: plugin, kinds: kinds)
        }
    }

    private var selectedParts: [PluginPart] { plugins.flatMap(\.parts).filter { checked.contains($0.id) } }

    var selectedTotal: Int64 { selectedParts.reduce(0) { $0 + $1.size } }

    /// Some selected part needs the administrator password.
    var selectionNeedsAdmin: Bool { selectedParts.contains(where: \.needsAdmin) }

    // MARK: removal

    func requestRemove() {
        guard phase == .ready, !selections.isEmpty else { return }
        confirming = true
    }

    func remove() async {
        confirming = false
        guard phase == .ready else { return }
        let selections = selections
        guard !selections.isEmpty else { return }
        phase = .removing
        let remover = remover
        let result = await Task.detached { await remover.remove(selections) }.value
        switch result {
        case .cancelled:
            // the password prompt was dismissed: nothing changed, keep the selection
            phase = .ready
        case .finished(let report, let byPolicy):
            lastRemoved = byPolicy
            phase = .report(report)
        }
    }

    /// Closes the report and rescans, since a removal can change what a plugin still has.
    func closeReport() {
        guard case .report = phase else { return }
        phase = .ready
        startScan()
    }

    func reveal(_ url: URL) {
        if !revealer.reveal(url) { missingItem = url }
    }
}
