import AppKit
import SiftCore
import SwiftUI

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Width of the size column, so sizes line up across rows.
let sizeColumnWidth: CGFloat = 80

/// Right-aligned size in the shared size column.
struct SizeText: View {
    let text: String

    init(_ bytes: Int64?) { text = bytes.map(formatBytes) ?? "—" }

    init(text: String) { self.text = text }

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: sizeColumnWidth, alignment: .trailing)
    }
}

/// Tri-state checkbox; a click on a mixed box checks everything. Exposed to VoiceOver as a toggle
/// with the item's name and an on/off/mixed value.
struct TriStateCheckBox: View {
    let state: JunkModel.CheckState
    /// Accessible name of the item the box selects.
    let name: String
    let set: (Bool) -> Void

    var body: some View {
        Button {
            set(state != .on)
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(LocalizedStringKey(valueKey)))
        .accessibilityAddTraits(.isToggle)
        .help(Text(LocalizedStringKey(valueKey)))
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }

    private var valueKey: String {
        switch state {
        case .on: "Selected"
        case .mixed: "Partly selected"
        case .off: "Not selected"
        }
    }
}

/// "Show in Finder" and "Copy Path" for a result row.
struct RevealMenu: View {
    let url: URL
    let reveal: (URL) -> Void

    var body: some View {
        Button("Show in Finder") { reveal(url) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }
}

extension View {
    /// Alert shown when "Show in Finder" targets an item that has gone since the scan.
    func missingItemAlert(_ item: Binding<URL?>) -> some View {
        alert(
            "This item no longer exists.",
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        ) {
            Button("OK") { item.wrappedValue = nil }
        } message: {
            Text(verbatim: item.wrappedValue?.path ?? "")
        }
    }
}

/// A centered symbol, title, explanation and optional actions, for empty and starting states.
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title2)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                // no vertical fixedSize: while the window measures its minimum size it proposes ~0 width,
                // the text then wraps per character and its height would push the sidebar out of view
                .frame(maxWidth: 440)
            actions.padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReportSheet: View {
    let report: RemovalReport
    let context: ReportContext
    let paths: SiftPaths
    let reveal: (URL) -> Void
    /// Removed items per policy when one operation both deleted and trashed (Junk); nil means all
    /// items followed the context's policy.
    var removedByPolicy: [RemovalPolicy: [RemovedItem]]? = nil
    let onClose: () -> Void

    private var outcome: ReportOutcome { ReportOutcome(report) }

    private var policy: RemovalPolicy { context.policy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: outcome.symbol)
                    .font(.system(size: 32))
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(outcome.titleKey(context: context))).font(.title2)
                    amountLine.font(.headline)
                }
            }
            noteLine.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !report.skipped.isEmpty {
                Text("Not removed: \(report.skipped.count) items").font(.headline).padding(.top, 4)
                List(report.skipped, id: \.url) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: paths.displayPath(item.url))
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(item.url.path)
                        Text(LocalizedStringKey(item.reason.titleKey)).font(.caption)
                        if let hint = item.reason.hintKey {
                            Text(LocalizedStringKey(hint)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu { RevealMenu(url: item.url, reveal: reveal) }
                }
                .frame(minHeight: 120)
            }
            if report.stopped && !report.unprocessed.isEmpty {
                Text("Stopped: \(report.unprocessed.count) items not removed").font(.headline).padding(.top, 4)
                Text("Stopping does not undo items already removed.").font(.caption).foregroundStyle(.secondary)
                List(report.unprocessed) { item in
                    Text(verbatim: paths.displayPath(item.url))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(item.url.path)
                        .contextMenu { RevealMenu(url: item.url, reveal: reveal) }
                }
                .frame(minHeight: 100, maxHeight: 180)
            }
            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 200)
    }

    private var symbolColor: Color {
        switch outcome {
        case .success: .green
        case .partial: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }

    /// Removed items for `policy`: from the per-policy split when given, else all or nothing.
    func removed(_ policy: RemovalPolicy) -> [RemovedItem] {
        if let removedByPolicy { return removedByPolicy[policy] ?? [] }
        return policy == self.policy ? report.removed : []
    }

    private func bytes(_ items: [RemovedItem]) -> Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }

    /// Policies to describe: those that removed something, or the context's own when nothing was removed.
    var shownPolicies: [RemovalPolicy] {
        let used = [RemovalPolicy.delete, .trash].filter { !removed($0).isEmpty }
        return used.isEmpty ? [policy] : used
    }

    @ViewBuilder private var amountLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shownPolicies, id: \.self) { policy in
                let items = removed(policy)
                if policy == .trash {
                    Text("Moved to Trash: \(items.count) items, \(formatBytes(bytes(items)))")
                } else {
                    Text("Deleted files totaling \(formatBytes(bytes(items))) (\(items.count) items)")
                }
            }
        }
    }

    @ViewBuilder private var noteLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shownPolicies, id: \.self) { policy in
                if policy == .trash {
                    Text("Disk space is freed when you empty the Trash.")
                } else {
                    Text("Free space may take a while to update because of APFS local snapshots.")
                }
            }
        }
    }
}
