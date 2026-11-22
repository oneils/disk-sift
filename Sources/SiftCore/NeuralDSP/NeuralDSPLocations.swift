import Foundation

/// One kind of file a Neural DSP plugin installs, each in its own folder and named after the plugin
/// (https://support.neuraldsp.com/help/plugin-file-location).
public enum PluginPartKind: String, CaseIterable, Sendable {
    case au, vst, vst3, aax, app, presets, manual, settings

    /// The folder holding this kind for every plugin. Never removable itself.
    public func root(_ paths: SiftPaths) -> URL {
        let plugIns = paths.systemLibrary.appendingPathComponent("Audio/Plug-Ins", isDirectory: true)
        switch self {
        case .au: return plugIns.appendingPathComponent("Components", isDirectory: true)
        case .vst: return plugIns.appendingPathComponent("VST", isDirectory: true)
        case .vst3: return plugIns.appendingPathComponent("VST3", isDirectory: true)
        case .aax:
            return paths.systemLibrary.appendingPathComponent(
                "Application Support/Avid/Audio/Plug-Ins", isDirectory: true)
        case .app: return paths.applications.appendingPathComponent("Neural DSP", isDirectory: true)
        case .presets:
            return paths.systemLibrary.appendingPathComponent("Audio/Presets/Neural DSP", isDirectory: true)
        case .manual:
            return paths.systemLibrary.appendingPathComponent("Application Support/Neural DSP", isDirectory: true)
        case .settings:
            return paths.library.appendingPathComponent("Application Support/Neural DSP", isDirectory: true)
        }
    }

    /// Bundle extension; nil for kinds that are plain folders named after the plugin.
    public var pathExtension: String? {
        switch self {
        case .au: "component"
        case .vst: "vst"
        case .vst3: "vst3"
        case .aax: "aaxplugin"
        case .app: "app"
        case .presets, .manual, .settings: nil
        }
    }

    /// Suffix of this kind's package receipt (`com.neuraldsp.<Name><Suffix>.pkg`); settings have none.
    public var receiptSuffix: String? {
        switch self {
        case .au: "AU"
        case .vst: "VST"
        case .vst3: "VST3"
        case .aax: "AAX"
        case .app: "App"
        case .presets: "Presets"
        case .manual: "Manual"
        case .settings: nil
        }
    }

    /// AU, VST, VST3, AAX and the app: what makes a plugin installed rather than leftovers.
    public var isBundle: Bool { pathExtension != nil }

    /// The root's canonical path, or nil when it is missing, isn't a real directory (a symlink is refused),
    /// or resolves somewhere other than where `SiftPaths` puts it.
    public func canonicalRoot(_ paths: SiftPaths) -> CanonicalPath? {
        // not standardizedFileURL: it strips `/private`, which realpath keeps
        let root = root(paths)
        var st = stat()
        guard lstat(root.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
            let resolved = realpath(root.path, nil)
        else { return nil }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        guard canonical.lowercased() == root.path.lowercased() else { return nil }
        return try? CanonicalPath.of(URL(fileURLWithPath: canonical))
    }
}

/// One installed piece of a plugin.
public struct PluginPart: Identifiable, Equatable, Sendable {
    public var kind: PluginPartKind
    public var url: URL
    public var size: Int64
    public var inaccessible: Bool
    /// Presets only: the `User` folder holds the user's own presets.
    public var containsUserPresets: Bool
    /// The user can't move it to the Trash (something inside is root-owned); removing it needs a password.
    /// A hint for the UI: the remover recomputes it.
    public var needsAdmin: Bool

    public var id: String { url.path }

    public init(
        kind: PluginPartKind, url: URL, size: Int64, inaccessible: Bool = false, containsUserPresets: Bool = false,
        needsAdmin: Bool = false
    ) {
        self.kind = kind
        self.url = url
        self.size = size
        self.inaccessible = inaccessible
        self.containsUserPresets = containsUserPresets
        self.needsAdmin = needsAdmin
    }
}

/// Everything one Neural DSP plugin left on disk, grouped by its name.
public struct NeuralDSPPlugin: Identifiable, Equatable, Sendable {
    /// e.g. "Archetype Nolly X".
    public var name: String
    /// In `PluginPartKind` order.
    public var parts: [PluginPart]
    /// Package receipt IDs, sorted.
    public var receipts: [String]

    public var id: String { name }

    public init(name: String, parts: [PluginPart], receipts: [String] = []) {
        self.name = name
        self.parts = parts
        self.receipts = receipts
    }

    public var totalSize: Int64 { parts.reduce(0) { $0 + $1.size } }

    /// False for leftovers of a removed plugin (only manual, presets, settings or receipts remain).
    public var hasPluginBundles: Bool { parts.contains { $0.kind.isBundle } }
}

public enum NeuralDSPLocations {
    /// The plugin name an entry of `kind`'s root stands for, or nil when the entry doesn't belong there.
    public static func partName(of entry: String, kind: PluginPartKind) -> String? {
        guard !entry.hasPrefix("."), !entry.isEmpty else { return nil }
        guard let ext = kind.pathExtension else { return entry }
        let nsEntry = entry as NSString
        guard nsEntry.pathExtension.lowercased() == ext else { return nil }
        let name = nsEntry.deletingPathExtension
        return name.isEmpty ? nil : name
    }

    /// The plug-in folders are shared with every vendor (Kontakt, Ozone, Apple's own AU), so a bundle counts
    /// only when its `CFBundleIdentifier` starts with `com.neuraldsp.` (Neural DSP writes `com.NeuralDSP.`).
    public static func isNeuralDSPBundle(_ url: URL) -> Bool {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let id = dict["CFBundleIdentifier"] as? String
        else { return false }
        return id.lowercased().hasPrefix("com.neuraldsp.")
    }

    /// Receipt IDs of `name`: `com.neuraldsp.<name without spaces><kind suffix>.pkg`, matched exactly.
    public static func receiptPattern(for name: String) -> Regex<AnyRegexOutput>? {
        let base = NSRegularExpression.escapedPattern(for: name.replacingOccurrences(of: " ", with: ""))
        let suffixes = PluginPartKind.allCases.compactMap(\.receiptSuffix).joined(separator: "|")
        return try? Regex("^com\\.neuraldsp\\.\(base)(\(suffixes))\\.pkg$")
    }

    /// The part kind a receipt of `name` belongs to, or nil when it isn't one of `name`'s receipts.
    public static func receiptKind(_ receipt: String, of name: String) -> PluginPartKind? {
        guard let pattern = receiptPattern(for: name),
            let match = try? pattern.wholeMatch(in: receipt),
            match.count > 1, let suffix = match[1].substring
        else { return nil }
        return PluginPartKind.allCases.first { $0.receiptSuffix == String(suffix) }
    }
}
