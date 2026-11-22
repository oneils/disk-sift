import SiftCore
import SwiftUI

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct UninstallView: View {
    @Bindable var model: UninstallModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
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
                    ReportSheet(report: report, title: "Uninstall finished") { model.reset() }
                }
            }
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
            dropZone
        case .scanning:
            VStack(spacing: 8) {
                ProgressView()
                Text("Looking for leftovers…")
            }
        case .removing:
            VStack(spacing: 8) {
                ProgressView()
                Text("Moving to Trash…")
            }
        case .results:
            results
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.app").font(.system(size: 44))
            Text("Drop an application here")
                .font(.title3)
            Text("Applications from /Applications or ~/Applications")
                .foregroundStyle(.secondary)
            if let key = model.errorKey {
                Text(LocalizedStringKey(key)).foregroundStyle(.red)
            }
        }
        .padding(40)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    model.isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .padding(20)
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.app?.name ?? "").font(.headline)
                Spacer()
                Button("Cancel") { model.reset() }
            }
            .padding()
            List {
                ForEach(model.groups) { group in
                    SwiftUI.Section(group.parent.path) {
                        ForEach(group.findings) { finding in
                            FindingRow(model: model, finding: finding)
                        }
                    }
                }
            }
            HStack {
                Text("Selected: \(formatBytes(model.selectedTotal))")
                Spacer()
                Button("Move to Trash") { Task { await model.trash() } }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }
}

private struct FindingRow: View {
    @Bindable var model: UninstallModel
    let finding: Finding

    var body: some View {
        HStack {
            Toggle(
                isOn: Binding(
                    get: { model.isChecked(finding) }, set: { model.setChecked(finding, $0) })
            ) {
                Text(finding.url.lastPathComponent)
            }
            .disabled(finding.requiresRoot)
            Spacer()
            if finding.requiresRoot { Text("Needs admin").foregroundStyle(.secondary) }
            Text(LocalizedStringKey(finding.confidence.titleKey))
                .font(.caption)
                .padding(.horizontal, 6)
                .background(.quaternary, in: Capsule())
            Text(finding.size.map(formatBytes) ?? "—")
                .monospacedDigit().foregroundStyle(.secondary)
        }
        .opacity(finding.requiresRoot ? 0.5 : 1)
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
}

struct ReportSheet: View {
    let report: RemovalReport
    let title: String
    let onClose: () -> Void

    private var removedBytes: Int64 { report.removed.reduce(0) { $0 + ($1.size ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).font(.title2)
            Text("Removed: \(report.removed.count) items, \(formatBytes(removedBytes))")
            if !report.skipped.isEmpty {
                Text("Skipped: \(report.skipped.count) items").foregroundStyle(.orange)
                List(report.skipped, id: \.url) { item in
                    VStack(alignment: .leading) {
                        Text(item.url.path).lineLimit(1).truncationMode(.middle)
                        Text(LocalizedStringKey(item.reason.titleKey)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120)
            }
            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 200)
    }
}

extension SkipReason {
    var titleKey: String {
        switch self {
        case .outsideRoots: "Outside the allowed locations"
        case .needsAdmin: "Needs administrator rights"
        case .permissionDenied: "Permission denied"
        case .inUse: "In use"
        case .vanished: "Already gone"
        case .appNotRemoved: "Left alone because the app could not be removed"
        }
    }
}
