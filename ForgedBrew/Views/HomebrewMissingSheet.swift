import SwiftUI
import AppKit

// MARK: - HomebrewMissingSheet
// First-run gate shown when Homebrew isn't installed on this Mac. ForgedBrew is a
// Homebrew front-end — without brew there's nothing it can manage — so rather
// than failing silently or showing empty lists, we greet new users with a
// clear, friendly explanation and a one-tap path to install Homebrew:
//   • A "Get Homebrew" button that opens https://brew.sh in the browser.
//   • The official one-line install command, copyable to the clipboard so a
//     user can paste it straight into Terminal.
// The sheet is non-dismissable via the close button alone in the sense that it
// always offers an explicit "I'll do this later" escape — we never trap the
// user, but we make the recommended action obvious.
struct HomebrewMissingSheet: View {
    // Bound to AppDataService.brewMissing via the WindowGroup. Setting it false
    // dismisses the sheet.
    @Binding var isPresented: Bool

    // The canonical Homebrew install command from https://brew.sh.
    private let installCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    // Brief "Copied!" confirmation after the user copies the command.
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)

            // Headline + explanation
            VStack(spacing: 8) {
                Text("Homebrew isn’t installed")
                    .font(.system(size: 20, weight: .bold))
                Text("""
                ForgedBrew manages the apps and command-line tools you install with \
                Homebrew. It looks like Homebrew isn’t on this Mac yet — install \
                it once and ForgedBrew takes care of the rest.
                """)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Install command block (copyable)
            VStack(alignment: .leading, spacing: 8) {
                Text("Install command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 10) {
                    Text(installCommand)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        copyCommand()
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(OutlinedButtonStyle())
                    .help(didCopy ? "Copied!" : "Copy command")
                }
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )

                Text("Paste this into Terminal, then relaunch ForgedBrew.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Primary + secondary actions
            VStack(spacing: 10) {
                Button {
                    openHomebrewSite()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app")
                        Text("Get Homebrew")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)

                Button("I’ll do this later") {
                    isPresented = false
                }
                .buttonStyle(OutlinedButtonStyle())
                .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 420)
    }

    private func copyCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(installCommand, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }

    private func openHomebrewSite() {
        if let url = URL(string: "https://brew.sh") {
            NSWorkspace.shared.open(url)
        }
    }
}
