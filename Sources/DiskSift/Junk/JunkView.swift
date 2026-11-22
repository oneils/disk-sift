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
                            JunkItemRow(
                                model: model, node: model.node(for: finding, categoryID: row.id),
                                requiresRoot: finding.requiresRoot)
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
            .disabled(model.phase == .deleting)
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
                ReportSheet(
                    report: report, policy: .delete, title: report.stopped ? "Cleanup stopped" : "Cleanup finished"
                ) {
                    model.closeReport()
                }
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
            } else if model.phase == .deleting {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView().controlSize(.small)
                        if let p = model.deletingProgress {
                            Text("Deleting: \(p.current.url.lastPathComponent)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(p.current.url.path)
                        } else {
                            Text("Deleting…")
                        }
                    }
                    if let p = model.deletingProgress {
                        Text("\(p.completed) of \(p.total) done • \(formatBytes(p.processedBytes)) deleted")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(
                            LocalizedStringKey(
                                model.isStopping ? "Stopping after current item…" : "Stop after current item")
                        ) {
                            model.stopDelete()
                        }
                        .disabled(model.isStopping)
                    }
                }
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
    let node: JunkModel.Node
    var requiresRoot = false

    var body: some View {
        if model.canExpand(node, requiresRoot: requiresRoot) {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { model.isExpanded(node.id) }, set: { model.setExpanded(node, $0) })
            ) {
                ForEach(model.children(of: node.id)) { child in
                    JunkItemRow(model: model, node: child)
                }
            } label: {
                line
            }
        } else {
            line
        }
    }

    private var line: some View {
        HStack {
            CheckBox(state: model.state(of: node.id)) { on in model.setChecked(id: node.id, on) }
                .disabled(requiresRoot)
            Text(node.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.isLoading(node.id) { ProgressView().controlSize(.small) }
            if requiresRoot { Text("Needs admin").foregroundStyle(.secondary) }
            Text(node.depth == 0 && node.size == 0 && !requiresRoot ? "—" : formatBytes(node.size))
                .monospacedDigit().foregroundStyle(.secondary)
        }
        .opacity(requiresRoot ? 0.5 : 1)
        .help(node.url.path)
    }
}

/// Tri-state checkbox; a click on a mixed box checks everything.
private struct CheckBox: View {
    let state: JunkModel.CheckState
    let set: (Bool) -> Void

    var body: some View {
        Button {
            set(state != .on)
        } label: {
            Image(systemName: symbol).foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }
}
