import AppKit
import SiftCore
import SwiftUI

struct LargeFilesView: View {
    @Bindable var model: LargeFilesModel

    var body: some View {
        content
            .sheet(isPresented: reportBinding) {
                if case .report(let report) = model.phase {
                    ReportSheet(
                        report: report, context: .largeFiles, paths: model.paths, reveal: { model.reveal($0) }
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
        if !model.hasScanned {
            EmptyStateView(
                symbol: "doc.text.magnifyingglass",
                title: "Find large files",
                message:
                    "DiskSift looks for large files in your home folder. It skips ~/Library, the Trash, ~/Applications, apps and media libraries, Git folders and other volumes. Files you select are moved to the Trash, never deleted."
            ) {
                VStack(spacing: 12) {
                    thresholdPicker.fixedSize()
                    Button("Start Scan") { model.startScan() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                list
                Divider()
                footer
            }
        }
    }

    private var thresholdPicker: some View {
        Picker("Files over", selection: $model.threshold) {
            ForEach(LargeFilesModel.thresholds, id: \.self) { Text(verbatim: formatBytes($0)).tag($0) }
        }
    }

    // MARK: header

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .scanning:
                HStack {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scanning: \(model.scannedCount) items checked")
                        if let dir = model.currentDirectory {
                            Text(verbatim: model.paths.displayPath(dir))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button("Stop") { model.stop() }
                }
            case .trashing:
                trashingHeader
            default:
                summary
            }
        }
        .padding()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Found \(model.visibleRows.count) files, \(formatBytes(model.visibleTotal))").font(.headline)
                Spacer()
                thresholdPicker.fixedSize()
                Picker("Sort by", selection: $model.sort) {
                    ForEach(LargeFileSort.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button("Scan Again") { model.startScan() }
            }
            if model.scanStopped {
                Label {
                    Text("The scan was stopped. The list is incomplete.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
            if !model.unreadable.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.unreadable, id: \.self) { url in
                            Text(verbatim: model.paths.displayPath(url))
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } label: {
                    Text("\(model.unreadable.count) folders could not be read and were not scanned.")
                        .font(.callout)
                }
            }
        }
    }

    private var trashingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                if let p = model.trashProgress {
                    Text("Moving to Trash: \(p.current.url.lastPathComponent)")
                        .lineLimit(1).truncationMode(.middle)
                        .help(p.current.url.path)
                } else {
                    Text("Moving to Trash…")
                }
            }
            if let p = model.trashProgress {
                Text("\(p.completed) of \(p.total) done • \(formatBytes(p.processedBytes)) moved to Trash")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(
                    LocalizedStringKey(
                        model.isStopping ? "Stopping after current item…" : "Stop after current item")
                ) {
                    model.stopTrash()
                }
                .disabled(model.isStopping)
            }
        }
    }

    // MARK: list

    @ViewBuilder private var list: some View {
        let rows = model.visibleRows
        if rows.isEmpty && model.phase != .scanning {
            Text("No files over \(formatBytes(model.threshold)) were found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(rows) { row in
                LargeFileRow(model: model, row: row)
            }
            .disabled(model.phase == .trashing)
        }
    }

    private var footer: some View {
        HStack {
            Text("Selected: \(formatBytes(model.selectedTotal))").font(.headline)
            Spacer()
            Button("Move to Trash") { Task { await model.trash() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase != .ready || model.selectedRows.isEmpty)
        }
        .padding()
    }
}

private struct LargeFileRow: View {
    @Bindable var model: LargeFilesModel
    let row: LargeFilesModel.Row

    var body: some View {
        let name = row.file.url.lastPathComponent
        HStack(alignment: .center, spacing: 8) {
            Toggle(
                isOn: Binding(get: { model.isChecked(row) }, set: { model.setChecked(row, $0) })
            ) {
                Text(verbatim: name)
            }
            .labelsHidden()
            .accessibilityLabel(Text(verbatim: name))
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.file.url.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).lineLimit(1).truncationMode(.middle)
                Text(verbatim: model.paths.displayPath(row.file.url.deletingLastPathComponent()))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            dateText.font(.caption).foregroundStyle(.secondary)
            SizeText(row.file.size)
        }
        .help(row.file.url.path)
        .contextMenu { RevealMenu(url: row.file.url, reveal: { model.reveal($0) }) }
    }

    @ViewBuilder private var dateText: some View {
        let shown = row.shownDate
        if let date = shown.date {
            let text = date.formatted(date: .abbreviated, time: .omitted)
            if shown.isOpened {
                Text("Opened \(text)")
            } else {
                Text("Modified \(text)")
            }
        }
    }
}
