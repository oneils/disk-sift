import SiftCore
import SwiftUI

/// Neural DSP plugins and leftovers of removed ones; the user picks what to remove (nothing preselected).
struct PluginsView: View {
    @Bindable var model: PluginsModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .confirmationDialog(confirmTitle, isPresented: $model.confirming, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { await model.remove() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                if model.selectionNeedsAdmin {
                    Text(
                        "Plugin files and manuals are deleted permanently after you enter an administrator password. Apps, presets and settings you can remove yourself are moved to the Trash. Quit your DAW first."
                    )
                } else {
                    Text("The selected items are moved to the Trash. Quit your DAW first.")
                }
            }
            .sheet(isPresented: reportBinding) {
                if case .report(let report) = model.phase {
                    ReportSheet(
                        report: report, context: .plugins, paths: model.paths, reveal: { model.reveal($0) },
                        removedByPolicy: model.lastRemoved
                    ) {
                        model.closeReport()
                    }
                }
            }
            .missingItemAlert($model.missingItem)
    }

    private var confirmTitle: Text {
        Text("Remove the selected plugins (\(formatBytes(model.selectedTotal)))?")
    }

    private var reportBinding: Binding<Bool> {
        Binding(
            get: { if case .report = model.phase { true } else { false } },
            set: { if !$0 { model.closeReport() } })
    }

    @ViewBuilder private var content: some View {
        if !model.hasScanned {
            EmptyStateView(
                symbol: "pianokeys",
                title: "Find Neural DSP plugins",
                message:
                    "DiskSift lists Neural DSP plugins (AU, VST, VST3, AAX and the standalone apps) with their presets, manuals and settings, including what removed plugins left behind. You choose which plugins to remove."
            ) {
                Button("Start Scan") { model.startScan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        } else if model.phase == .scanning && model.plugins.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking for Neural DSP plugins…")
            }
        } else if model.foundNothing {
            EmptyStateView(
                symbol: "checkmark.circle",
                title: "No Neural DSP plugins found",
                message: "None of the Neural DSP plugin folders contain anything."
            ) {
                Button("Scan Again") { model.startScan() }
                    .controlSize(.large)
            }
        } else {
            results
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Neural DSP plugins: \(model.plugins.count)").font(.headline)
                Spacer()
                if model.phase == .scanning || model.phase == .removing { ProgressView().controlSize(.small) }
                Button("Scan Again") { model.startScan() }
                    .disabled(model.phase != .ready)
            }
            .padding()
            Divider()
            List {
                ForEach(model.plugins) { plugin in
                    DisclosureGroup(isExpanded: expandedBinding(plugin.id)) {
                        ForEach(plugin.parts) { part in PluginPartRow(model: model, part: part) }
                    } label: {
                        PluginLabel(model: model, plugin: plugin)
                    }
                }
            }
            .disabled(model.phase != .ready)
            Divider()
            HStack {
                Text("Selected: \(formatBytes(model.selectedTotal))").font(.headline)
                Spacer()
                Button("Remove…") { model.requestRemove() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase != .ready || model.selections.isEmpty)
            }
            .padding()
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.expanded.contains(id) },
            set: { if $0 { model.expanded.insert(id) } else { model.expanded.remove(id) } })
    }
}

extension PluginPartKind {
    /// English localization key.
    var titleKey: String {
        switch self {
        case .au: "AU"
        case .vst: "VST"
        case .vst3: "VST3"
        case .aax: "AAX"
        case .app: "App"
        case .presets: "Presets"
        case .manual: "Manual"
        case .settings: "Settings"
        }
    }
}

private struct PluginLabel: View {
    @Bindable var model: PluginsModel
    let plugin: NeuralDSPPlugin

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            TriStateCheckBox(state: model.state(of: plugin), name: plugin.name) { model.setPlugin(plugin, $0) }
            Image(systemName: plugin.hasPluginBundles ? "pianokeys" : "archivebox")
                .foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: plugin.name).font(.headline)
                let kinds = plugin.parts.map { NSLocalizedString($0.kind.titleKey, comment: "") }
                    .joined(separator: " · ")
                if plugin.hasPluginBundles {
                    Text(verbatim: kinds).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Leftovers: \(kinds)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            SizeText(plugin.totalSize)
        }
        .padding(.vertical, 2)
    }
}

private struct PluginPartRow: View {
    @Bindable var model: PluginsModel
    let part: PluginPart

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            TriStateCheckBox(
                state: model.isChecked(part) ? .on : .off, name: NSLocalizedString(part.kind.titleKey, comment: "")
            ) { model.setChecked(part, $0) }
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(part.kind.titleKey))
                Text(verbatim: model.paths.displayPath(part.url))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if part.needsAdmin {
                    Text("Needs an administrator password; deleted permanently.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if part.containsUserPresets {
                    Text("Contains your own presets (User folder); not selected with the plugin.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if part.inaccessible {
                    Text("Some contents could not be read; the size may be incomplete.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            SizeText(part.size)
        }
        .help(part.url.path)
        .contextMenu { RevealMenu(url: part.url, reveal: { model.reveal($0) }) }
    }
}
