import SiftCore
import SwiftUI

struct JunkView: View {
    @Bindable var model: JunkModel

    var body: some View {
        content
            .confirmationDialog(confirmTitle, isPresented: $model.confirming, titleVisibility: .visible) {
                if model.selectedDeleteTotal > 0 {
                    Button("Delete", role: .destructive) { Task { await model.remove() } }
                } else {
                    Button("Move to Trash") { Task { await model.remove() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                confirmMessage
            }
            .sheet(isPresented: reportBinding) {
                if case .report(let report) = model.phase {
                    ReportSheet(
                        report: report, context: .cleanup, paths: model.paths, reveal: { model.reveal($0) },
                        removedByPolicy: model.lastRemoved
                    ) {
                        model.closeReport()
                    }
                }
            }
            .missingItemAlert($model.missingItem)
    }

    private var confirmTitle: Text {
        let delete = formatBytes(model.selectedDeleteTotal)
        let trash = formatBytes(model.selectedTrashTotal)
        switch (model.selectedDeleteTotal > 0, model.selectedTrashTotal > 0) {
        case (true, true): return Text("Delete \(delete) permanently and move \(trash) to the Trash?")
        case (false, true): return Text("Move \(trash) to the Trash?")
        default: return Text("Delete \(delete) permanently?")
        }
    }

    @ViewBuilder private var confirmMessage: some View {
        switch (model.selectedDeleteTotal > 0, model.selectedTrashTotal > 0) {
        case (true, true):
            Text(
                "Caches, logs and Mail downloads are deleted immediately. Installers and device backups are moved to the Trash, so you can put them back."
            )
        case (false, true):
            Text("Items are moved to the Trash, so you can put them back.")
        default:
            Text(
                "Files are deleted immediately, not moved to the Trash. On APFS the free space may take a while to show up because of local snapshots."
            )
        }
    }

    @ViewBuilder private var content: some View {
        if !model.hasScanned {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "Find junk files",
                message:
                    "DiskSift checks your user caches and logs (~/Library/Caches, ~/Library/Logs), developer caches (Xcode, CoreSimulator, Homebrew, npm, pip, Cargo and Go), installers in Downloads and on the Desktop, local iPhone and iPad backups, and Mail downloads. System-wide caches are not scanned."
            ) {
                Button("Start Scan") { model.startScan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        } else if model.foundNothing {
            EmptyStateView(
                symbol: "checkmark.circle",
                title: "No junk found",
                message: "The scanned locations contain nothing to clean."
            ) {
                Button("Scan Again") { model.startScan() }
                    .controlSize(.large)
            }
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                List {
                    ForEach(model.rows) { row in
                        DisclosureGroup(isExpanded: expandedBinding(row.id)) {
                            ForEach(model.sortedFindings(row)) { finding in
                                JunkItemRow(
                                    model: model, node: model.node(for: finding, categoryID: row.id),
                                    requiresRoot: finding.requiresRoot)
                            }
                        } label: {
                            CategoryLabel(model: model, row: row)
                        }
                    }
                }
                .disabled(model.phase == .removing)
                Divider()
                footer
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

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .scanning:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Scanning: \(model.finishedCount) of \(model.rows.count) done")
                    Spacer()
                    Button("Stop") { model.stop() }
                }
            case .removing:
                removingHeader
            default:
                summaryHeader
            }
        }
        .padding()
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Found \(formatBytes(model.foundTotal)) in \(model.foundCount) items").font(.headline)
                Spacer()
                Picker("Sort by", selection: $model.sort) {
                    ForEach(ResultSort.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button("Scan Again") { model.startScan() }
            }
            if model.scanStopped {
                Label {
                    Text("The scan was stopped. Categories marked Incomplete were not fully scanned.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
            DistributionBar(model: model)
        }
    }

    private var removingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                if let p = model.removalProgress {
                    Text("Removing: \(p.current.url.lastPathComponent)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(p.current.url.path)
                } else {
                    Text("Removing…")
                }
            }
            if let p = model.removalProgress {
                Text("\(p.completed) of \(p.total) done • \(formatBytes(p.processedBytes)) removed")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(
                    LocalizedStringKey(
                        model.isStopping ? "Stopping after current item…" : "Stop after current item")
                ) {
                    model.stopRemove()
                }
                .disabled(model.isStopping)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Selected: \(formatBytes(model.selectedTotal))").font(.headline)
            Spacer()
            Button("Clean Up…") { model.requestRemove() }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase != .ready || model.selectedFindings.isEmpty)
        }
        .padding()
    }
}

private struct CategoryLabel: View {
    @Bindable var model: JunkModel
    let row: JunkModel.Row

    var body: some View {
        let title = NSLocalizedString(row.title, comment: "")
        HStack(alignment: .firstTextBaseline) {
            TriStateCheckBox(state: model.categoryState(row), name: title) { model.setCategoryChecked(row, $0) }
                .disabled(!model.hasSelectable(row) || model.phase == .removing)
            Image(systemName: JunkCategoryInfo.symbol(row.id)).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.headline)
                if let note = JunkCategoryInfo.noteKey(row.id) {
                    Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            status
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        switch row.state {
        case .pending:
            Text("Waiting…").foregroundStyle(.secondary)
        case .scanning:
            ProgressView().controlSize(.small)
            SizeText(text: formatBytes(row.total))
        case .noAccess:
            Text("No access").foregroundStyle(.orange)
                .help(Text("Grant Full Disk Access in System Settings, then scan again."))
        case .stopped:
            Text("Incomplete").foregroundStyle(.orange)
            SizeText(text: "≥ " + formatBytes(row.total))
        case .done:
            SizeText(row.total)
        }
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
                ForEach(model.sortedChildren(of: node.id)) { child in
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
        HStack(alignment: .firstTextBaseline) {
            TriStateCheckBox(state: model.state(of: node.id), name: node.title) { on in
                model.setChecked(id: node.id, on)
            }
            .disabled(requiresRoot)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: node.title).lineLimit(1).truncationMode(.middle)
                if node.depth == 0 {
                    Text(verbatim: model.paths.displayPath(node.url))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let note = JunkCategoryInfo.itemNoteKey(node.url) {
                        Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if requiresRoot {
                    Text("Needs administrator rights; DiskSift will not remove it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if node.inaccessible {
                    Text("Some contents could not be read; the size may be incomplete.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isLoading(node.id) { ProgressView().controlSize(.small) }
            SizeText(text: node.depth == 0 && node.size == 0 && !requiresRoot ? "—" : formatBytes(node.size))
        }
        .opacity(requiresRoot ? 0.6 : 1)
        .help(node.url.path)
        .contextMenu { RevealMenu(url: node.url, reveal: { model.reveal($0) }) }
    }
}

/// One bar of what the scan found, split by category, with a legend carrying exact values.
/// Categories never overlap and children are not counted, so the parts add up to the list total.
private struct DistributionBar: View {
    let model: JunkModel

    private static let palette: [Color] = [.accentColor, .purple, .teal, .pink]

    private var parts: [(row: JunkModel.Row, color: Color)] {
        model.rows.enumerated().filter { $0.element.total > 0 }
            .map { ($0.element, Self.palette[$0.offset % Self.palette.count]) }
    }

    var body: some View {
        let total = max(model.foundTotal, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let gaps = CGFloat(max(parts.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(parts, id: \.row.id) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(
                                width: max(2, (geo.size.width - gaps) * CGFloat(part.row.total) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                ForEach(parts, id: \.row.id) { part in
                    HStack(spacing: 6) {
                        Circle().fill(part.color).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(LocalizedStringKey(part.row.title))
                        Text(verbatim: "\(formatBytes(part.row.total)) · \(percent(part.row.total, of: total))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer()
            }
            .font(.caption)
            Text(
                model.scanStopped
                    ? "Found data only (incomplete scan), not total disk usage or guaranteed free space."
                    : "Found data only, not total disk usage or guaranteed free space."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func percent(_ part: Int64, of total: Int64) -> String {
        (Double(part) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// What deleting each junk category (and notable item) means.
enum JunkCategoryInfo {
    static func symbol(_ categoryID: String) -> String {
        switch categoryID {
        case DevJunkCategory.categoryID: "hammer"
        case InstallersCategory.categoryID: "arrow.down.doc"
        case IOSBackupsCategory.categoryID: "iphone"
        case MailDownloadsCategory.categoryID: "envelope"
        default: "archivebox"
        }
    }

    static func noteKey(_ categoryID: String) -> String? {
        switch categoryID {
        case UserCachesCategory.categoryID:
            "Apps recreate caches as needed; the next launch may be slower. Nothing is selected by default."
        case DevJunkCategory.categoryID:
            "Build products and package caches; rebuilt or downloaded again when needed."
        case InstallersCategory.categoryID:
            "Disk images and packages in Downloads and on the Desktop. Moved to the Trash; those older than 30 days are selected."
        case IOSBackupsCategory.categoryID:
            "Local backups of your devices; this may be the only copy of a device's data. Moved to the Trash; nothing is selected."
        case MailDownloadsCategory.categoryID:
            "Attachments Mail saved when you opened them; Mail downloads them again when needed. Deleted permanently."
        default: nil
        }
    }

    static func itemNoteKey(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if path.hasSuffix("/Xcode/Archives") {
            return "Contains debug symbols needed to read crash reports. Not selected by default."
        }
        if path.hasSuffix("/Xcode/DerivedData") { return "Rebuilt on the next build." }
        if path.hasSuffix("/Xcode/iOS DeviceSupport") { return "Downloaded again when a device is connected." }
        return nil
    }
}
