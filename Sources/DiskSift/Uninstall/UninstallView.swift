import AppKit
import SiftCore
import SwiftUI
import UniformTypeIdentifiers

struct UninstallView: View {
    @Bindable var model: UninstallModel
    /// Opens the "leftovers of removed apps" flow.
    var findLeftovers: () -> Void = {}

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                guard model.canChooseApp else { return false }
                Task { await model.drop(urls) }
                return true
            } isTargeted: {
                model.isTargeted = $0
            }
            .confirmationDialog(
                quitTitle, isPresented: quitBinding, titleVisibility: .visible
            ) {
                Button("Quit and Continue") { Task { await model.confirmQuit() } }
                Button("Cancel", role: .cancel) { model.declineQuit() }
            } message: {
                Text("The application is running and must be quit before it can be removed.")
            }
            .sheet(isPresented: reportBinding) {
                if case .report(let report) = model.phase {
                    ReportSheet(
                        report: report, context: .uninstall, paths: model.paths, reveal: { model.reveal($0) }
                    ) {
                        model.reset()
                    }
                }
            }
            .missingItemAlert($model.missingItem)
    }

    private var quitTitle: LocalizedStringKey {
        LocalizedStringKey("Quit \(model.app?.name ?? "")?")
    }

    private var quitBinding: Binding<Bool> {
        Binding(
            get: { if case .quitPrompt = model.phase { true } else { false } },
            set: { if !$0 { model.declineQuit() } })
    }

    private var reportBinding: Binding<Bool> {
        Binding(
            get: { if case .report = model.phase { true } else { false } },
            set: { if !$0 { model.reset() } })
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .validating, .quitPrompt, .report:
            chooser
        case .scanning:
            VStack(spacing: 8) {
                ProgressView()
                Text("Looking for leftovers…")
            }
        case .removing:
            removing
        case .results:
            results
        }
    }

    // MARK: choosing an app

    /// Opens a native picker in /Applications; cancelling it changes nothing.
    private func chooseApp() {
        guard model.canChooseApp else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = model.paths.applications
        panel.prompt = NSLocalizedString("Choose", comment: "Open panel button")
        panel.message = NSLocalizedString("Choose an application to uninstall", comment: "Open panel message")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await model.select(url) }
        }
    }

    private var chooser: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Drop an application here").font(.title2)
            Text("or").foregroundStyle(.secondary)
            Button(model.errorKey == nil ? "Choose Application…" : "Choose Another Application…") { chooseApp() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.canChooseApp)
            Text("Applications from /Applications or ~/Applications")
                .foregroundStyle(.secondary)
            Button("Find Leftovers of Removed Apps…", action: findLeftovers)
                .disabled(!model.canChooseApp)
                .help(Text("Look for files that apps you already deleted left in your Library."))
                .padding(.top, 16)
            if model.phase == .validating {
                ProgressView().controlSize(.small)
            }
            if let key = model.errorKey {
                Label {
                    Text(LocalizedStringKey(key))
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    model.isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .padding(20)
                .accessibilityHidden(true)
        }
    }

    // MARK: removing

    private var removing: some View {
        VStack(spacing: 12) {
            ProgressView()
            if let p = model.removalProgress {
                Text("Moving to Trash: \(p.current.url.lastPathComponent)")
                    .font(.headline)
                    .help(p.current.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(p.completed) of \(p.total) done • \(formatBytes(p.processedBytes)) moved to Trash")
                    .foregroundStyle(.secondary)
            } else {
                Text("Moving to Trash…")
                    .font(.headline)
            }
            Button(
                LocalizedStringKey(model.isStopping ? "Stopping after current item…" : "Stop after current item")
            ) {
                model.stop()
            }
            .disabled(model.isStopping)
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: results

    private var results: some View {
        VStack(spacing: 0) {
            if let app = model.app {
                AppSummary(model: model, app: app).padding()
            }
            Divider()
            HStack {
                Text("Related files").font(.headline)
                Spacer()
                Picker("Sort by", selection: $model.sort) {
                    ForEach(ResultSort.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(model.groups.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            if model.groups.isEmpty {
                Text("No related files were found. Only the application will be moved to the Trash.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.orderedGroups) { group in
                        SwiftUI.Section {
                            ForEach(model.sortedFindings(group)) { finding in
                                FindingRow(model: model, finding: finding)
                            }
                        } header: {
                            GroupHeader(model: model, group: group)
                        }
                    }
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total to move to Trash: \(formatBytes(model.totalToTrash))").font(.headline)
                    Text(
                        "Application \(formatBytes(model.appSize ?? 0)) + selected files \(formatBytes(model.selectedTotal))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.reset() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") { Task { await model.trash() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }
}

/// Icon, name, version and sizes of the app; identifiers live in a collapsed details section.
private struct AppSummary: View {
    @Bindable var model: UninstallModel
    let app: AppInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: app.name).font(.title2).lineLimit(1)
                        if let version = app.version {
                            Text("Version \(version)").foregroundStyle(.secondary)
                        }
                    }
                    Text(
                        "Application \(model.appSize.map(formatBytes) ?? "—") • Related files \(formatBytes(model.leftoversTotal)) in \(model.leftoversCount) items"
                    )
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            DisclosureGroup("Details", isExpanded: $model.showsDetails) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Location").foregroundStyle(.secondary)
                        Text(verbatim: model.paths.displayPath(app.url)).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Bundle ID").foregroundStyle(.secondary)
                        Text(verbatim: app.bundleID).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Team ID").foregroundStyle(.secondary)
                        if let team = app.signing.teamID {
                            Text(verbatim: team).textSelection(.enabled)
                        } else {
                            Text("Not signed by a registered developer")
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 4)
            }
        }
    }
}

private struct GroupHeader: View {
    let model: UninstallModel
    let group: FindingGroup

    var body: some View {
        let kind = model.kind(of: group)
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: kind.symbol).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(kind.titleKey))
                    if model.isSystem(group) {
                        Text("(all users)").foregroundStyle(.secondary)
                    }
                }
                .font(.headline)
                Text(verbatim: model.paths.displayPath(group.parent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            SizeText(text: (group.hasUnknownSize ? "≥ " : "") + formatBytes(group.totalSize))
        }
        .padding(.vertical, 2)
    }
}

private struct FindingRow: View {
    @Bindable var model: UninstallModel
    let finding: Finding

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(
                    isOn: Binding(
                        get: { model.isChecked(finding) }, set: { model.setChecked(finding, $0) })
                ) {
                    Text(verbatim: finding.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                .disabled(finding.requiresRoot)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(finding.evidenceKeys, id: \.self) { key in
                        Text(LocalizedStringKey(key))
                    }
                    if finding.isShared {
                        Label("Shared data: other apps may use it.", systemImage: "person.2.fill")
                            .foregroundStyle(.orange)
                    }
                    if finding.requiresRoot {
                        Text("Needs administrator rights; DiskSift will not remove it.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
            }
            Spacer()
            Text(LocalizedStringKey(finding.confidence.titleKey))
                .font(.caption)
                .padding(.horizontal, 6)
                .background(.quaternary, in: Capsule())
                .help(Text(LocalizedStringKey(finding.confidence.helpKey)))
                .accessibilityLabel(Text(LocalizedStringKey(finding.confidence.helpKey)))
            SizeText(finding.size)
        }
        .padding(.vertical, 2)
        .opacity(finding.requiresRoot ? 0.6 : 1)
        .help(finding.url.path)
        .contextMenu { RevealMenu(url: finding.url, reveal: { model.reveal($0) }) }
    }
}

extension Confidence {
    var titleKey: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// What the confidence means for the default selection.
    var helpKey: String {
        switch self {
        case .low: "Weak match: not selected by default. Review before removing."
        case .medium: "Possible match: review before removing."
        case .high: "Strong match: selected by default."
        }
    }
}

extension Finding {
    /// One English localization key per piece of evidence, strongest first.
    var evidenceKeys: [String] {
        MatchEvidence.allCases.filter { evidence.contains($0) }.map(\.explanationKey)
    }
}

extension MatchEvidence {
    var explanationKey: String {
        switch self {
        case .bundleIDName: "Named after the app's bundle identifier."
        case .appName: "Matched only by the app's name; it may belong to another app."
        case .appGroup: "App group container listed in the app's signature."
        case .teamPrefix: "Matched only by the developer's Team ID; it may belong to another app from that developer."
        case .otherAppInstalled: "Another installed app uses a matching identifier; this may be its data."
        case .launchLabel: "Background service labeled with the app's bundle identifier."
        case .launchProgramInApp: "Background service that runs a program inside the app."
        case .privilegedHelper: "Privileged helper installed for the app."
        case .pkgReceipt: "Installed by the app's installer package."
        case .appNotInstalled: "No installed app uses this bundle identifier."
        case .launchProgramMissing: "Background service whose program no longer exists."
        }
    }
}

extension LocationKind {
    var titleKey: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .savedState: "Saved Application State"
        case .logs: "Logs"
        case .webData: "Web Data and Cookies"
        case .loginServices: "Login Services"
        case .applicationScripts: "Application Scripts"
        case .autosave: "Autosave Information"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .applicationSupport: "folder"
        case .caches: "internaldrive"
        case .preferences: "gearshape"
        case .containers, .groupContainers: "shippingbox"
        case .savedState, .autosave: "clock.arrow.circlepath"
        case .logs: "doc.text"
        case .webData: "globe"
        case .loginServices: "power"
        case .applicationScripts: "applescript"
        case .other: "doc"
        }
    }
}
