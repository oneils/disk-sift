import SiftCore
import SwiftUI

/// Where space goes in the home folder: breadcrumbs, the current folder's children largest first with
/// a bar of their share, click a folder to go in. Items outside `~/Library` can be moved to the Trash.
struct SpaceLensView: View {
    @Bindable var model: SpaceLensModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: reportBinding) {
                if case .report(let report) = model.phase {
                    ReportSheet(report: report, context: .spaceLens, paths: model.paths, reveal: { model.reveal($0) }) {
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
            EmptyStateView(
                symbol: "chart.bar.doc.horizontal",
                title: "See where space goes",
                message:
                    "Space Lens measures every folder in your home folder, including Library, and lets you drill down to what takes the space. Files and folders outside Library, apps and Git repositories can be moved to the Trash. A large home folder can take several minutes to scan."
            ) {
                Button("Start Scan") { model.startScan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        case .scanning:
            VStack(spacing: 12) {
                ProgressView()
                Text("Measuring your home folder…").font(.headline)
                if let p = model.progress {
                    Text("\(p.items) items, \(formatBytes(p.bytes))").monospacedDigit().foregroundStyle(.secondary)
                }
                Button("Stop") { model.stop() }
            }
        case .ready, .report:
            browser
        case .removing:
            VStack(spacing: 12) {
                ProgressView()
                if let p = model.removalProgress {
                    Text("Moving to Trash: \(p.current.url.lastPathComponent)")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
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
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Button {
                        model.goUp()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(model.current == 0)
                    .help(Text("Enclosing folder"))
                    .accessibilityLabel(Text("Enclosing folder"))
                    breadcrumbs
                    Spacer()
                    SizeText(model.currentSize).font(.headline)
                    Button("Scan Again") { model.startScan() }
                }
                if model.currentInaccessible {
                    Label(
                        "Some folders could not be read (Full Disk Access may be needed); sizes are partial.",
                        systemImage: "lock"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            if model.rows.isEmpty {
                Text("This folder is empty.").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows) { row in
                            SpaceRow(model: model, row: row, total: max(model.currentSize, 1))
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                            Divider().padding(.leading)
                        }
                    }
                }
            }
            Divider()
            SpaceLensFooter(model: model)
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let crumbs = model.breadcrumbs
                ForEach(Array(crumbs.enumerated()), id: \.element.index) { offset, crumb in
                    if offset > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                    Button(crumb.name) { model.open(crumb.index) }
                        .buttonStyle(.link)
                        .disabled(crumb.index == model.current)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct SpaceLensFooter: View {
    let model: SpaceLensModel

    var body: some View {
        HStack {
            Text("Selected: \(formatBytes(model.selectedTotal))").font(.headline)
            Spacer()
            Button("Move to Trash") { Task { await model.remove() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase != .ready || !model.hasSelection)
        }
        .padding()
    }
}

private struct SpaceRow: View {
    let model: SpaceLensModel
    let row: SpaceLensModel.Row
    let total: Int64

    private var title: String {
        if case .otherFiles(let count) = row.kind {
            return String(format: NSLocalizedString("Smaller files: %lld", comment: ""), count)
        }
        return row.name
    }

    private var symbol: String {
        switch row.kind {
        case .directory: "folder"
        case .package: "shippingbox"
        case .file: "doc"
        case .otherFiles: "doc.on.doc"
        }
    }

    var body: some View {
        let covered = model.isCoveredBySelection(row)
        HStack(spacing: 8) {
            TriStateCheckBox(state: model.isChecked(row) || covered ? .on : .off, name: title) {
                model.setChecked(row, $0)
            }
            .disabled(!row.removable || covered)
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            if row.kind == .directory {
                Button {
                    model.open(row.id)
                } label: {
                    Text(verbatim: title).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
            } else {
                Text(verbatim: title).lineLimit(1).truncationMode(.middle)
            }
            if row.inaccessible {
                Image(systemName: "lock").foregroundStyle(.secondary)
                    .help(Text("Some contents could not be read; the size may be incomplete."))
            }
            Spacer(minLength: 12)
            ShareBar(fraction: Double(row.size) / Double(total))
                .frame(width: 120, height: 8)
                .accessibilityHidden(true)
            SizeText(row.size).frame(minWidth: 72, alignment: .trailing)
            if row.kind == .directory {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(row.id) }
        .help(row.url.path)
        .contextMenu { RevealMenu(url: row.url, reveal: { model.reveal($0) }) }
    }
}

/// A row's share of the folder it's in.
private struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor).frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
    }
}
