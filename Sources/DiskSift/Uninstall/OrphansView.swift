import SiftCore
import SwiftUI

/// Leftovers of apps that are no longer installed, grouped by app; nothing is preselected.
struct OrphansView: View {
    @Bindable var model: OrphansModel
    let fdaGranted: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: reportBinding) {
                if case .report(let report) = model.phase {
                    ReportSheet(
                        report: report, context: .leftovers, paths: model.paths, reveal: { model.reveal($0) }
                    ) {
                        model.closeReport()
                    }
                }
            }
            .missingItemAlert($model.missingItem)
    }

    private var reportBinding: Binding<Bool> {
        Binding(
            get: { if case .report = model.phase { true } else { false } },
            set: { if !$0 { model.closeReport() } })
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .scanning:
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking for leftovers of removed apps…")
                Button("Stop") { model.stop() }
            }
        case .results, .report:
            if model.groups.isEmpty {
                EmptyStateView(
                    symbol: "checkmark.circle",
                    title: "No leftovers of removed apps found",
                    message: fdaGranted
                        ? "Nothing in your Library belongs to an app that is no longer installed."
                        : "Nothing in your Library belongs to an app that is no longer installed. Containers were not checked without Full Disk Access."
                ) {
                    HStack {
                        Button("Back") { model.close() }
                        Button("Scan Again") { model.startScan() }
                    }
                }
            } else {
                results
            }
        case .removing:
            removing
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Button {
                        model.close()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    Text("Leftovers of removed apps").font(.headline)
                    Spacer()
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(ResultSort.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Button("Scan Again") { model.startScan() }
                }
                Text("Found \(formatBytes(model.foundTotal)) in \(model.foundCount) items")
                Text("Apps that are no longer installed left these items. Review them: nothing is selected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !fdaGranted {
                    Label("Containers were not checked without Full Disk Access.", systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            // a lazy stack, not List: with thousands of self-sizing rows the AppKit table behind List
            // stutters while scrolling, and only visible rows are built here
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sortedGroups) { section in
                        SwiftUI.Section {
                            ForEach(section.rows) { row in
                                OrphanRow(model: model, row: row)
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                Divider().padding(.leading)
                            }
                        } header: {
                            OrphanGroupHeader(model: model, section: section)
                        }
                    }
                }
            }
            Divider()
            OrphansFooter(model: model)
        }
    }

    private var removing: some View {
        VStack(spacing: 12) {
            ProgressView()
            if let p = model.removalProgress {
                Text("Moving to Trash: \(p.current.url.lastPathComponent)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(p.current.url.path)
                Text("\(p.completed) of \(p.total) done • \(formatBytes(p.processedBytes)) moved to Trash")
                    .foregroundStyle(.secondary)
            } else {
                Text("Moving to Trash…").font(.headline)
            }
            Button(
                LocalizedStringKey(model.isStopping ? "Stopping after current item…" : "Stop after current item")
            ) {
                model.stopRemove()
            }
            .disabled(model.isStopping)
        }
        .padding()
    }
}

/// Group header; reads only its own group's selection count.
private struct OrphanGroupHeader: View {
    let model: OrphansModel
    let section: OrphanSection

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            TriStateCheckBox(state: model.groupState(section), name: section.id) { model.setGroup(section, $0) }
                .disabled(section.selectableIDs.isEmpty)
            Text(verbatim: section.id).font(.headline)
            Text("\(section.rows.count) items").foregroundStyle(.secondary)
            Spacer()
            SizeText(section.totalSize)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Selected total and the action; the only part of the screen that depends on the whole selection.
private struct OrphansFooter: View {
    let model: OrphansModel

    var body: some View {
        HStack {
            Text("Selected: \(formatBytes(model.selectedTotal))").font(.headline)
            Spacer()
            Button("Move to Trash") { Task { await model.remove() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase != .results || !model.hasSelection)
        }
        .padding()
    }
}

private struct OrphanRow: View {
    let model: OrphansModel
    let row: OrphanRowData

    var body: some View {
        let finding = row.finding
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: Binding(get: { model.isChecked(id: row.id) }, set: { model.setChecked(finding, $0) })) {
                    Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
                }
                .disabled(finding.requiresRoot)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(row.kindKey))
                        Text(verbatim: "·")
                        Text(verbatim: row.parentPath).lineLimit(1).truncationMode(.middle)
                    }
                    ForEach(row.evidenceKeys, id: \.self) { Text(LocalizedStringKey($0)) }
                    if finding.requiresRoot {
                        Text("Needs administrator rights; DiskSift will not remove it.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
            }
            Spacer()
            SizeText(finding.size)
        }
        .opacity(finding.requiresRoot ? 0.6 : 1)
        .help(row.id)
        .contextMenu { RevealMenu(url: finding.url, reveal: { model.reveal($0) }) }
    }
}
