import Foundation

/// Why an app cannot be uninstalled.
public enum ValidationError: Error, Equatable, Sendable {
    case notAnApp
    case notFound
    case symlink
    case nestedInBundle
    case outsideApplications
    case onVolume
    case translocated
    case unreadableInfoPlist
    case missingBundleID
    case isSelf
    case appleApp
    case notRemovable
}

/// Facts about an installed `.app` used to find its leftovers.
public struct AppInfo: Sendable {
    public var url: URL
    public var bundleID: String
    public var name: String
    /// `CFBundleShortVersionString`, when present.
    public var version: String?
    public var signing: SigningInfo
    public var nestedBundleIDs: [String]

    public init(
        url: URL, bundleID: String, name: String, version: String? = nil, signing: SigningInfo,
        nestedBundleIDs: [String]
    ) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.signing = signing
        self.nestedBundleIDs = nestedBundleIDs
    }

    /// Directories inside the bundle that hold nested bundles with their own IDs.
    static let nestedDirs = [
        "Contents/Library/LoginItems", "Contents/PlugIns", "Contents/XPCServices", "Contents/Helpers",
        "Contents/Library/LaunchServices",
    ]

    /// Reads `Contents/Info.plist` and nested bundle IDs. Signing is read separately (`SigningInfo.read`).
    public static func load(_ url: URL, signing: SigningInfo = .unsigned) throws -> AppInfo {
        guard let plist = readPlist(url.appendingPathComponent("Contents/Info.plist")) else {
            throw ValidationError.unreadableInfoPlist
        }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw ValidationError.missingBundleID
        }
        let fallback = url.deletingPathExtension().lastPathComponent
        let name =
            [plist["CFBundleDisplayName"], plist["CFBundleName"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty } ?? fallback
        let version = (plist["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AppInfo(
            url: url, bundleID: bundleID, name: name, version: version, signing: signing,
            nestedBundleIDs: nestedBundleIDs(in: url, excluding: bundleID))
    }

    private static func nestedBundleIDs(in app: URL, excluding mainID: String) -> [String] {
        var seen: Set<String> = [mainID]
        var result: [String] = []
        for dir in nestedDirs {
            let dirURL = app.appendingPathComponent(dir, isDirectory: true)
            let children =
                (try? FileManager.default.contentsOfDirectory(atPath: dirURL.path))?.sorted() ?? []
            for child in children {
                let bundle = dirURL.appendingPathComponent(child)
                let plist =
                    readPlist(bundle.appendingPathComponent("Contents/Info.plist"))
                    ?? readPlist(bundle.appendingPathComponent("Info.plist"))
                if let id = plist?["CFBundleIdentifier"] as? String, !id.isEmpty, seen.insert(id).inserted {
                    result.append(id)
                }
            }
        }
        return result
    }

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
