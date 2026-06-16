import SwiftUI
import AppKit

struct FullDiskAccessBanner: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 18))
                .foregroundStyle(granted ? .green : .orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(granted ? "Full Disk Access granted" : "Grant Full Disk Access")
                    .font(.system(size: 13, weight: granted ? .medium : .semibold))

                Text(granted ? "Cleanup and cache sizes are accurate." : "ForgedBrew needs Full Disk Access to clean Homebrew's cache and show accurate cleanup numbers.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !granted {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(granted ? AnyShapeStyle(Color.green.opacity(0.08)) : AnyShapeStyle(Color.orange.opacity(0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}
