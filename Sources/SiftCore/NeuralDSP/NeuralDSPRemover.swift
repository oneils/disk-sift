import Foundation

/// The parts of one plugin the user chose to remove.
public struct PluginSelection: Sendable {
    public var plugin: NeuralDSPPlugin
    public var kinds: Set<PluginPartKind>

    public init(plugin: NeuralDSPPlugin, kinds: Set<PluginPartKind>) {
        self.plugin = plugin
        self.kinds = kinds
    }
}

public enum PluginRemovalResult: Sendable {
    /// The password prompt was cancelled: nothing was removed or moved.
    case cancelled
    /// What was removed, per policy (`.delete` for the administrator step, `.trash` for the rest).
    case finished(RemovalReport, [RemovalPolicy: [RemovedItem]])
}

/// Removes selected Neural DSP plugin parts. The one place in DiskSift that removes root-owned items:
/// every path is re-validated (a real directory directly inside its kind's root, named after the plugin),
/// root-owned parts go through `PrivilegedRunner` first (so a cancelled prompt changes nothing), and
/// the rest goes to the Trash through `Remover`.
public struct NeuralDSPRemover: Sendable {
    private let paths: SiftPaths
    private let privileged: any PrivilegedRunner
    private let runningApps: any RunningApps
    private let trasher: any Trasher
    private let runner: any CommandRunner

    public init(
        paths: SiftPaths, privileged: any PrivilegedRunner, runningApps: any RunningApps,
        trasher: any Trasher = FileManagerTrasher(), runner: any CommandRunner = ProcessCommandRunner()
    ) {
        self.paths = paths
        self.privileged = privileged
        self.runningApps = runningApps
        self.trasher = trasher
        self.runner = runner
    }

    private struct RootPart {
        var removal: PrivilegedRemoval
        var url: URL
        var size: Int64
    }

    public func remove(_ selections: [PluginSelection]) async -> PluginRemovalResult {
        var roots: [PluginPartKind: CanonicalPath] = [:]
        for kind in PluginPartKind.allCases { roots[kind] = kind.canonicalRoot(paths) }
        let running = Set(
            runningApps.running().compactMap { $0.bundleURL }.compactMap { try? CanonicalPath.of($0).path.lowercased() }
        )

        var skipped: [SkippedItem] = []
        var trash: [Finding] = []
        var rootParts: [RootPart] = []
        var receipts: [String] = []

        for selection in selections where !selection.kinds.isEmpty {
            let plugin = selection.plugin
            let chosen = plugin.parts.filter { selection.kinds.contains($0.kind) }
            let appRunning = plugin.parts.contains { part in
                part.kind == .app && (try? CanonicalPath.of(part.url).path.lowercased()).map(running.contains) == true
            }
            if appRunning {
                skipped += chosen.map { SkippedItem(url: $0.url, reason: .inUse) }
                continue
            }
            var trashKinds: Set<PluginPartKind> = []
            for part in chosen {
                guard let (root, name) = validate(part, plugin: plugin.name, roots: roots) else {
                    skipped.append(
                        SkippedItem(url: part.url, reason: Self.exists(part.url) ? .outsideRoots : .vanished))
                    continue
                }
                let url = root.url.appendingPathComponent(name, isDirectory: true)
                if Writability.canTrashDeep(url) {
                    trashKinds.insert(part.kind)
                    trash.append(
                        Finding(
                            url: url, size: part.size, confidence: .high, sources: [.plugin(name: plugin.name)]))
                } else {
                    let receipt = plugin.receipts.first {
                        NeuralDSPLocations.receiptKind($0, of: plugin.name) == part.kind
                    }
                    rootParts.append(
                        RootPart(
                            removal: PrivilegedRemoval(parent: root.path, name: name, receipt: receipt), url: url,
                            size: part.size))
                }
            }
            // receipts of trashed parts, and of parts already gone from disk; never of refused or kept parts
            let present = Set(plugin.parts.map(\.kind))
            for receipt in plugin.receipts {
                guard let kind = NeuralDSPLocations.receiptKind(receipt, of: plugin.name) else { continue }
                if trashKinds.contains(kind) || !present.contains(kind) { receipts.append(receipt) }
            }
        }

        var removed: [RemovalPolicy: [RemovedItem]] = [:]
        let outcome = await privileged.run(rootParts.map(\.removal), forgetting: receipts)
        switch outcome {
        case .cancelled:
            return .cancelled
        case .failed:
            // all or nothing on authorization: don't trash anything either
            skipped += rootParts.map {
                SkippedItem(url: $0.url, reason: Self.exists($0.url) ? .adminStepFailed : .vanished)
            }
            skipped += trash.map { SkippedItem(url: $0.url, reason: .adminStepFailed) }
            return .finished(Self.report(removed, skipped), removed)
        case .finished:
            break
        }
        for part in rootParts {
            if Self.exists(part.url) {
                skipped.append(SkippedItem(url: part.url, reason: .adminStepFailed))
            } else {
                removed[.delete, default: []].append(RemovedItem(url: part.url, size: part.size))
            }
        }
        if !trash.isEmpty {
            let remover = Remover(roots: RemovalRoots(roots: Array(roots.values)), trasher: trasher)
            let report = await remover.remove(trash, policy: .trash, onProgress: nil)
            removed[.trash, default: []] += report.removed
            skipped += report.skipped
        }
        await logUnforgottenReceipts(rootParts.compactMap(\.removal.receipt) + receipts)
        return .finished(Self.report(removed, skipped), removed)
    }

    /// The canonical root and entry name of a part that really belongs where it claims; nil otherwise.
    func validate(_ part: PluginPart, plugin: String, roots: [PluginPartKind: CanonicalPath]) -> (
        CanonicalPath, String
    )? {
        guard let root = roots[part.kind], let canonical = try? CanonicalPath.of(part.url) else { return nil }
        let parent = (canonical.path as NSString).deletingLastPathComponent
        let name = (canonical.path as NSString).lastPathComponent
        guard parent.lowercased() == root.path.lowercased(),
            NeuralDSPLocations.partName(of: name, kind: part.kind) == plugin,
            !name.contains("\n"), !name.contains("\0")
        else { return nil }
        var st = stat()
        guard lstat(canonical.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        if part.kind.isBundle && !NeuralDSPLocations.isNeuralDSPBundle(canonical.url) { return nil }
        return (root, name)
    }

    private static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    private static func report(_ removed: [RemovalPolicy: [RemovedItem]], _ skipped: [SkippedItem]) -> RemovalReport {
        RemovalReport(removed: (removed[.delete] ?? []) + (removed[.trash] ?? []), skipped: skipped)
    }

    private func logUnforgottenReceipts(_ requested: [String]) async {
        guard !requested.isEmpty,
            let result = try? await runner.run("/usr/sbin/pkgutil", ["--pkgs"]), result.status == 0
        else { return }
        let still = Set(result.stdout.split(whereSeparator: \.isNewline).map(String.init))
        for receipt in requested where still.contains(receipt) {
            Log.removal.info("receipt not forgotten: \(receipt, privacy: .public)")
        }
    }
}
