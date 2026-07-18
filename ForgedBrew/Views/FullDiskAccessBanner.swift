import SwiftUI
import AppKit

// MARK: - FullDiskAccessBanner
//
// A status strip shown on the Maintenance screen reporting whether macOS has
// granted ForgedBrew Full Disk Access (FDA). Several maintenance tools need FDA
// to work correctly -- clearing Homebrew's cache and measuring cleanup sizes
// reach into protected locations that macOS hides without it -- so this banner
// makes the requirement (and its current state) visible up front rather than
// letting those tools fail silently or report misleading numbers.
//
// `granted` is computed by the caller; this view is purely presentational and
// flips between two states:
//   • granted   -> a calm green "all good" confirmation, no action.
//   • not yet   -> an orange call-to-action that deep-links to the relevant
//                  System Settings privacy pane so the user can flip the switch.
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

                Text(granted ? "Cleanup and cache sizes are accurate." : "ForgedBrew needs Full Disk Access to clean Homebrew's cache and show accurate cleanup numbers. Turn it on in System Settings, then use Quit & Relaunch \u{2014} macOS only applies the change to a freshly launched app, and in menu-bar mode closing the window isn't enough.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Actions only appear when access is missing. First: deep-link
            // straight to the Full Disk Access list (Privacy_AllFiles) in System
            // Settings so the user lands on the exact toggle. Second: a one-click
            // full restart, because a just-granted FDA only takes effect on a
            // fresh process and closing a menu-bar app's window doesn't restart it.
            if !granted {
                HStack(spacing: 8) {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Quit & Relaunch") {
                        StartupSettings.shared.relaunch()
                    }
                    .controlSize(.small)
                    .help("Fully quits ForgedBrew and reopens it so a just-granted Full Disk Access takes effect.")
                }
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
