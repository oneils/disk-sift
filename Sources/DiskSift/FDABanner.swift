import AppKit
import SiftCore
import SwiftUI

struct FDABanner: View {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("Full Disk Access is not granted. Some leftovers can't be found without it.")
            Spacer()
            Button("Open Settings") { NSWorkspace.shared.open(Self.settingsURL) }
        }
        .padding(8)
        .background(.yellow.opacity(0.15))
    }
}
