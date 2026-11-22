import SiftCore
import SwiftUI

struct JunkView: View {
    @Bindable var model: JunkModel

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                ForEach(model.rows) { row in
                    DisclosureGroup(isExpanded: expandedBinding(row.id)) {
                        ForEach(row.findings) { finding in
                            JunkItemRow(model: model, finding: finding)
                        }
                    } label: {
                        HStack {
                            Toggle(
                                isOn: Binding(
                                    get: { model.isCategoryChecked(row) },
                                    set: { model.setCategoryChecked(row, $0) })
                            ) {
                                Text(LocalizedStringKey(row.title))
                            }
                            Spacer()
                            if row.state == .scanning { ProgressView().controlSize(.small) }
                            Text(formatBytes(row.total)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            footer
        }
        .confirmationDialog(
            Text("Delete \(formatBytes(model.selectedTotal)) permanently?"),
            isPresented: $model.confirming, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await model.delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Files are deleted immediately, not moved to the Trash. On APFS the free space may take a while to show up because of local snapshots."
            )
        }
        .sheet(isPresented: reportBinding) {
            if case .report(let report) = model.phase {
                ReportSheet(report: report, title: "Cleanup finished") { model.closeReport() }
            }
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.expanded.contains(id) },
            set: { if $0 { model.expanded.insert(id) } else { model.expanded.remove(id) } })
    }

    private var reportBinding: Binding<Bool> {
        Binding(
            get: { if case .report = model.phase { true } else { false } },
            set: { if !$0 { model.closeReport() } })
    }

    private var header: some View {
        HStack {
            if model.phase == .scanning {
                ProgressView().controlSize(.small)
                Text("Scanning: \(model.finishedCount) of \(model.rows.count) done")
                Spacer()
                Button("Stop") { model.stop() }
            } else {
                Spacer()
                Button("Scan") { model.startScan() }
                    .disabled(model.phase == .deleting)
            }
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Text("Selected: \(formatBytes(model.selectedTotal))")
            Spacer()
            Button("Delete…") { model.requestDelete() }
                .disabled(model.phase != .ready || model.selectedFindings.isEmpty)
        }
        .padding()
    }
}

private struct JunkItemRow: View {
    @Bindable var model: JunkModel
    let finding: Finding

    var body: some View {
        HStack {
            Toggle(
                isOn: Binding(
                    get: { model.isChecked(finding) }, set: { model.setChecked(finding, $0) })
            ) {
                Text(finding.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
            .disabled(finding.requiresRoot)
            Spacer()
            if finding.requiresRoot { Text("Needs admin").foregroundStyle(.secondary) }
            Text(finding.size.map(formatBytes) ?? "—").monospacedDigit().foregroundStyle(.secondary)
        }
        .opacity(finding.requiresRoot ? 0.5 : 1)
    }
}
