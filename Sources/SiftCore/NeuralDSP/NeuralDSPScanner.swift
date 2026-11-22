import Foundation

/// Finds what Neural DSP plugins installed, grouped by plugin name. Only real directories directly in
/// each kind's root count: symlinks, plain files, hidden entries and wrong extensions are ignored, and
/// bundles must carry a Neural DSP bundle ID (the plug-in folders hold every vendor's plugins).
public struct NeuralDSPScanner: Sendable {
    private let paths: SiftPaths
    private let runner: any CommandRunner

    public init(paths: SiftPaths, runner: any CommandRunner = ProcessCommandRunner()) {
        self.paths = paths
        self.runner = runner
    }

    /// Plugins, largest first. Cancellable.
    public func scan() async throws -> [NeuralDSPPlugin] {
        var byName: [String: [PluginPart]] = [:]
        for kind in PluginPartKind.allCases {
            try Task.checkCancellation()
            guard let root = kind.canonicalRoot(paths) else { continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
            for entry in names {
                guard let name = NeuralDSPLocations.partName(of: entry, kind: kind) else { continue }
                let url = root.url.appendingPathComponent(entry, isDirectory: true)
                var st = stat()
                guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
                if kind.isBundle && !NeuralDSPLocations.isNeuralDSPBundle(url) { continue }
                try Task.checkCancellation()
                let size = try await DirectorySizer.size(of: url)
                byName[name, default: []].append(
                    PluginPart(
                        kind: kind, url: url, size: size.bytes, inaccessible: size.inaccessible,
                        containsUserPresets: kind == .presets && Self.hasUserPresets(url),
                        needsAdmin: !Writability.canTrashDeep(url)))
            }
        }
        let receipts = await installedReceipts()
        return byName.map { name, parts in
            NeuralDSPPlugin(
                name: name, parts: parts,
                receipts: receipts.filter { NeuralDSPLocations.receiptKind($0, of: name) != nil }.sorted())
        }
        .sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.name < $1.name }
    }

    /// Neural DSP package receipts; empty when `pkgutil` fails.
    func installedReceipts() async -> [String] {
        guard let result = try? await runner.run("/usr/sbin/pkgutil", ["--pkgs"]), result.status == 0 else {
            Log.command.info("pkgutil --pkgs failed")
            return []
        }
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.hasPrefix("com.neuraldsp.") }
    }

    /// A `User` folder with at least one visible entry: the user's own presets.
    static func hasUserPresets(_ presets: URL) -> Bool {
        let user = presets.appendingPathComponent("User", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: user.path)) ?? []
        return names.contains { !$0.hasPrefix(".") }
    }
}
