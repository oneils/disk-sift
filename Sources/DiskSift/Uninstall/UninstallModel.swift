import AppKit
import Foundation
import SiftCore

protocol AppValidating: Sendable {
    func validate(_ url: URL) throws -> AppInfo
}

protocol LeftoverScanning: Sendable {
    func scan(_ app: AppInfo) async throws -> [Finding]
}

protocol AppUninstalling: Sendable {
    func uninstall(
        _ app: AppInfo,
        leftovers: [Finding],
        onProgress: (@Sendable (RemovalProgressState) async -> Void)?
    ) async -> RemovalReport
    func uninstall(_ app: AppInfo, leftovers: [Finding]) async -> RemovalReport
}

/// Asks running processes to quit (live: NSRunningApplication).
protocol ProcessTerminating: Sendable {
    func terminate(pid: Int32)
    func forceTerminate(pid: Int32)
}

extension AppValidator: AppValidating {}
extension LeftoverScanner: LeftoverScanning {}
extension Uninstaller: AppUninstalling {}

struct LiveProcessTerminator: ProcessTerminating {
    func terminate(pid: Int32) { _ = NSRunningApplication(processIdentifier: pid)?.terminate() }
    func forceTerminate(pid: Int32) { _ = NSRunningApplication(processIdentifier: pid)?.forceTerminate() }
}

extension ValidationError {
    /// English localization key for the inline message.
    var messageKey: String {
        switch self {
        case .notAnApp: "This is not an application."
        case .notFound: "The application was not found."
        case .symlink: "This is a symbolic link, not an application."
        case .nestedInBundle: "This application is nested inside another application."
        case .outsideApplications: "Only applications in /Applications or ~/Applications can be uninstalled."
        case .onVolume: "Applications on external volumes are not supported."
        case .translocated: "Move the application out of quarantine (to /Applications) first."
        case .unreadableInfoPlist: "The application's Info.plist can't be read."
        case .missingBundleID: "The application has no bundle identifier."
        case .isSelf: "DiskSift can't uninstall itself."
        case .appleApp: "Apple system applications can't be uninstalled."
        case .notRemovable: "This application needs administrator rights to remove."
        }
    }
}

@Observable
@MainActor
final class UninstallModel {
    enum Phase: Equatable {
        case idle
        case validating
        case quitPrompt(running: [RunningApp])
        case scanning
        case results
        case removing
        case report(RemovalReport)
    }

    private(set) var phase: Phase = .idle
    /// Localization key of the inline drop error.
    private(set) var errorKey: String?
    private(set) var app: AppInfo?
    private(set) var groups: [FindingGroup] = []
    private(set) var checked: Set<String> = []
    var isTargeted = false
    private(set) var isStopping = false
    private(set) var removalProgress: RemovalProgressState?
    private var removalTask: Task<RemovalReport, Never>?

    private let validator: any AppValidating
    private let scanner: any LeftoverScanning
    private let uninstaller: any AppUninstalling
    private let runningApps: any RunningApps
    private let terminator: any ProcessTerminating
    private let quitTimeout: Duration
    private let pollInterval: Duration

    init(
        validator: any AppValidating, scanner: any LeftoverScanning, uninstaller: any AppUninstalling,
        runningApps: any RunningApps, terminator: any ProcessTerminating,
        quitTimeout: Duration = .seconds(5), pollInterval: Duration = .milliseconds(200)
    ) {
        self.validator = validator
        self.scanner = scanner
        self.uninstaller = uninstaller
        self.runningApps = runningApps
        self.terminator = terminator
        self.quitTimeout = quitTimeout
        self.pollInterval = pollInterval
    }

    static func live(paths: SiftPaths = .live) -> UninstallModel {
        let runner = ProcessCommandRunner()
        let sources: [any LeftoverSource] = [
            LibraryPathsSource(installed: LiveInstalledApps()), LaunchItemsSource(),
            PkgReceiptsSource(runner: runner),
        ]
        return UninstallModel(
            validator: AppValidator(paths: paths),
            scanner: LeftoverScanner(sources: sources, paths: paths),
            uninstaller: Uninstaller(remover: Remover(roots: .make(paths)), runner: runner),
            runningApps: LiveRunningApps(), terminator: LiveProcessTerminator())
    }

    // MARK: drop and validation

    func drop(_ urls: [URL]) async {
        guard phase == .idle, let url = urls.first else { return }
        errorKey = nil
        phase = .validating
        let info: AppInfo
        do {
            info = try validator.validate(url)
        } catch let error as ValidationError {
            errorKey = error.messageKey
            phase = .idle
            return
        } catch {
            errorKey = ValidationError.notAnApp.messageKey
            phase = .idle
            return
        }
        app = info
        let running = Self.runningInstances(of: info, in: runningApps.running())
        if running.isEmpty {
            await scan()
        } else {
            phase = .quitPrompt(running: running)
        }
    }

    /// Running processes that belong to the app: by bundle ID (own or nested) or by living inside the bundle.
    nonisolated static func runningInstances(of app: AppInfo, in running: [RunningApp]) -> [RunningApp] {
        let ids = Set([app.bundleID] + app.nestedBundleIDs)
        let prefix = app.url.standardizedFileURL.path + "/"
        return running.filter { process in
            if let id = process.bundleID, ids.contains(id) { return true }
            guard let path = process.bundleURL?.standardizedFileURL.path else { return false }
            return path == app.url.standardizedFileURL.path || path.hasPrefix(prefix)
        }
    }

    func declineQuit() {
        guard case .quitPrompt = phase else { return }
        reset()
    }

    /// Terminates the running instances, waits, force-terminates stragglers, then scans.
    func confirmQuit() async {
        guard case .quitPrompt(let running) = phase, let app else { return }
        phase = .scanning
        for process in running { terminator.terminate(pid: process.pid) }
        var waited = Duration.zero
        var remaining = Self.runningInstances(of: app, in: runningApps.running())
        while !remaining.isEmpty, waited < quitTimeout {
            try? await Task.sleep(for: pollInterval)
            waited += pollInterval
            remaining = Self.runningInstances(of: app, in: runningApps.running())
        }
        for process in remaining { terminator.forceTerminate(pid: process.pid) }
        await scan()
    }

    // MARK: scan and selection

    private func scan() async {
        guard let app else { return }
        phase = .scanning
        do {
            let findings = try await scanner.scan(app)
            groups = FindingGroup.group(findings)
            checked = Set(findings.filter(LeftoverScanner.defaultChecked).map(\.id))
            phase = .results
        } catch {
            reset()
        }
    }

    func isChecked(_ finding: Finding) -> Bool { checked.contains(finding.id) }

    func setChecked(_ finding: Finding, _ on: Bool) {
        guard phase == .results, !finding.requiresRoot else { return }
        if on { checked.insert(finding.id) } else { checked.remove(finding.id) }
    }

    var selectedFindings: [Finding] {
        groups.flatMap(\.findings).filter { checked.contains($0.id) && !$0.requiresRoot }
    }

    /// Selected leftovers only; the app itself is always trashed.
    var selectedTotal: Int64 { selectedFindings.reduce(0) { $0 + ($1.size ?? 0) } }

    // MARK: removal

    func trash() async {
        guard phase == .results, let app else { return }
        phase = .removing
        isStopping = false
        removalProgress = nil
        let uninstaller = uninstaller
        let leftovers = selectedFindings
        let task = Task.detached {
            await uninstaller.uninstall(app, leftovers: leftovers) { state in
                await MainActor.run {
                    self.removalProgress = state
                }
            }
        }
        removalTask = task
        let report = await task.value
        isStopping = false
        removalTask = nil
        removalProgress = nil
        phase = .report(report)
    }

    func stop() {
        guard phase == .removing else { return }
        isStopping = true
        removalTask?.cancel()
    }

    func reset() {
        guard phase != .removing else { return }
        removalTask?.cancel()
        removalTask = nil
        removalProgress = nil
        phase = .idle
        app = nil
        groups = []
        checked = []
    }
}
