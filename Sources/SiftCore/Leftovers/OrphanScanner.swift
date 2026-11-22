import Foundation

/// Finds what apps that are no longer installed left in the user's Library: a reverse scan by bundle ID.
/// Detection is conservative: a name is reported only when nothing installed, running or registered
/// with Launch Services (outside the Trash) can own it.
public struct OrphanScanner: Sendable {
    private let paths: SiftPaths
    private let installed: any InstalledApps
    private let runningApps: any RunningApps
    private let hasFullDiskAccess: @Sendable (SiftPaths) -> Bool

    public init(
        paths: SiftPaths, installed: any InstalledApps, runningApps: any RunningApps,
        hasFullDiskAccess: @escaping @Sendable (SiftPaths) -> Bool = { FullDiskAccess.isGranted($0) }
    ) {
        self.paths = paths
        self.installed = installed
        self.runningApps = runningApps
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    /// `~/Library` subdirectories scanned by name. Group Containers hold data shared by a developer's
    /// apps and LaunchAgents are judged by program path, so neither is scanned by name.
    static let scannedSubdirs = ScanLocations.userLibrarySubdirs.filter {
        $0 != "Group Containers" && $0 != "LaunchAgents"
    }

    private struct Candidate {
        var url: URL
        var id: String
        var evidence: MatchEvidence
        var label: String?
    }

    /// Orphan groups, largest first. Cancellable.
    public func scan() async throws -> [OrphanGroup] {
        var alive = InstalledBundleIDs.collect(paths: paths)
        alive.formUnion(runningApps.running().compactMap { $0.bundleID?.lowercased() })
        let agents = launchAgents()
        alive.formUnion(agents.filter { !$0.programMissing }.map(\.label))
        var known: [String: Bool] = [:]
        func isAlive(_ id: String) -> Bool {
            if alive.contains(where: { id == $0 || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) { return true }
            if let cached = known[id] { return cached }
            let result = installed.isKnownOutsideTrash(bundleID: id)
            known[id] = result
            return result
        }

        var candidates: [Candidate] = []
        let fda = hasFullDiskAccess(paths)
        let protected = Set(ScanLocations.protectedDirs(paths).map { $0.standardizedFileURL.path })
        for subdir in Self.scannedSubdirs {
            try Task.checkCancellation()
            let dir = paths.library.appendingPathComponent(subdir, isDirectory: true)
            if !fda && protected.contains(dir.standardizedFileURL.path) { continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
            for name in names {
                guard let id = Self.candidateID(fromName: name, inByHost: subdir == "Preferences/ByHost"),
                    !isAlive(id)
                else { continue }
                candidates.append(Candidate(url: dir.appendingPathComponent(name), id: id, evidence: .appNotInstalled))
            }
        }
        for agent in agents where agent.programMissing && !isAlive(agent.label) {
            candidates.append(
                Candidate(url: agent.url, id: agent.label, evidence: .launchProgramMissing, label: agent.originalLabel))
        }

        let groupIDs = Set(candidates.map(\.id))
        var byGroup: [String: [Finding]] = [:]
        for candidate in candidates {
            try Task.checkCancellation()
            // the shortest orphan ID this one equals or extends
            let group =
                groupIDs.filter { candidate.id == $0 || candidate.id.hasPrefix($0 + ".") }.min { $0.count < $1.count }
                ?? candidate.id
            var sources: Set<FindingSource> = [.orphan(groupID: group)]
            if let label = candidate.label { sources.insert(.launchItem(label: label, domain: .user)) }
            let size = try await DirectorySizer.size(of: candidate.url)
            byGroup[group, default: []].append(
                Finding(
                    url: candidate.url, size: size.bytes, confidence: .medium, sources: sources,
                    requiresRoot: !Writability.canRemove(candidate.url, policy: .trash),
                    inaccessible: size.inaccessible,
                    evidence: [candidate.evidence]))
        }
        return byGroup.map { OrphanGroup(id: $0.key, findings: $0.value.sorted { $0.url.path < $1.url.path }) }
            .sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.id < $1.id }
    }

    private struct Agent {
        var url: URL
        var label: String
        var originalLabel: String
        /// The program was inside an Applications folder and is gone.
        var programMissing: Bool
    }

    /// User launch agents with their label and whether their program vanished from an Applications folder.
    private func launchAgents() -> [Agent] {
        let dir = paths.library.appendingPathComponent("LaunchAgents", isDirectory: true)
        let appRoots = [paths.applications, paths.userApplications].map { RemovalRoots.canonicalRoot($0) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
        var result: [Agent] = []
        for name in names where (name as NSString).pathExtension == "plist" {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else {
                Log.scan.info("skipping unreadable launch plist \(url.path, privacy: .public)")
                continue
            }
            let label = (plist["Label"] as? String) ?? (name as NSString).deletingPathExtension
            let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
            var missing = false
            if let program, program.hasPrefix("/") {
                var st = stat()
                // a missing program can't be realpath'd: resolve its nearest existing ancestor instead
                let resolved = RemovalRoots.canonicalRoot(URL(fileURLWithPath: program))
                missing =
                    lstat(program, &st) != 0 && appRoots.contains { resolved.isStrictlyInside($0) }
            }
            result.append(Agent(url: url, label: label.lowercased(), originalLabel: label, programMissing: missing))
        }
        return result
    }
    /// Shared vendor components and non-app owners whose data outlives any single app.
    /// Matched as the whole ID or a dotted prefix, case-insensitive.
    static let excludedPrefixes: [String] = [
        "com.microsoft.office", "com.microsoft.shared", "com.microsoft.autoupdate", "com.microsoft.autoupdate2",
        "com.adobe", "com.google.keystone", "org.python",
    ]

    /// Suffixes Library items add to a bundle ID (same list as `LibraryPathsSource`).
    static let knownExtensions = ["plist", "savedState", "binarycookies"]

    /// The bundle ID a Library item is named after, lowercased; nil when the name doesn't look like an
    /// app's bundle ID or belongs to something that is never an orphan.
    /// - Parameter inByHost: the item is in `Preferences/ByHost`, whose names end in a hardware UUID.
    public static func candidateID(fromName name: String, inByHost: Bool = false) -> String? {
        guard name.caseInsensitiveCompare("ByHost") != .orderedSame else { return nil }
        var base = name
        let ext = (base as NSString).pathExtension
        if knownExtensions.contains(ext) { base = (base as NSString).deletingPathExtension }
        var components = base.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if inByHost, let last = components.last, isHardwareID(last) { components.removeLast() }
        guard components.count >= 3, components.allSatisfy(isValidComponent) else { return nil }
        // "ABCDE12345.com.foo.shared": app-group data, skipped like Group Containers
        if isTeamID(components[0]) { return nil }
        let id = components.joined(separator: ".").lowercased()
        if id.hasPrefix("com.apple.") { return nil }
        if excludedPrefixes.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { return nil }
        return id
    }

    private static func isValidComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "-" || scalar == "_"
            }
    }

    /// 10 uppercase letters and digits, the shape of an Apple Team ID.
    static func isTeamID(_ component: String) -> Bool {
        component.count == 10
            && component.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// A ByHost suffix: a hardware UUID (`8-4-4-4-12` hex) or a legacy 12-hex MAC address.
    static func isHardwareID(_ component: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let parts = component.split(separator: "-", omittingEmptySubsequences: false)
        let lengths = parts.map(\.count)
        guard lengths == [8, 4, 4, 4, 12] || lengths == [12] else { return false }
        return parts.allSatisfy { $0.unicodeScalars.allSatisfy(hex.contains) }
    }
}

/// What one removed app left behind.
public struct OrphanGroup: Identifiable, Equatable, Sendable {
    /// The app's bundle ID, lowercased.
    public var id: String
    /// Sorted by path.
    public var findings: [Finding]

    public var totalSize: Int64 { findings.reduce(0) { $0 + ($1.size ?? 0) } }

    public init(id: String, findings: [Finding]) {
        self.id = id
        self.findings = findings
    }
}
