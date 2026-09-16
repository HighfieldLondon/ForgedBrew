import SwiftUI
import AppKit

// MARK: - XcodeLicenseSheet
// Shown when Homebrew refuses to run because the Xcode license hasn't been
// accepted. Homebrew's own launcher (brew.sh) runs `xcrun --find clang` before
// dispatching ANY command and dies if that mentions "license" — so every brew
// call ForgedBrew makes fails, and until 2.4.8 that surfaced as an empty
// Installed list with no explanation. A new Xcode version re-arms the gate, so
// this recurs after every major Xcode update; it is worth a proper gate of its
// own, in the same spirit as HomebrewMissingSheet:
//   • Says plainly what's wrong and why the lists are empty.
//   • "Accept now" runs `sudo xcodebuild -license accept` for the user,
//     authenticated with the administrator password they type here (the same
//     askpass channel brew updates use), then refreshes everything.
//   • The Terminal command is shown and copyable for anyone who'd rather do it
//     themselves, plus an explicit "I'll do this later" escape.
struct XcodeLicenseSheet: View {
    // Bound to AppDataService.xcodeLicenseRequired via the WindowGroup.
    @Binding var isPresented: Bool
    @Environment(AppDataService.self) private var appData

    private let command = "sudo xcodebuild -license accept"

    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)

            VStack(spacing: 8) {
                Text("Homebrew needs the Xcode license accepted")
                    .font(.system(size: 20, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("""
                Xcode was updated and its new license hasn’t been accepted yet. \
                Homebrew refuses to run until it is — which is why your installed \
                apps and updates aren’t showing. Accepting it takes a moment and \
                needs your administrator password.
                """)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Inline password + Accept. Kept inside this sheet (rather than
            // raising the shared sudo prompt) because SwiftUI presents one sheet
            // at a time — stacking a second would fail silently.
            VStack(alignment: .leading, spacing: 8) {
                Text("Administrator password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                        .onSubmit { accept() }
                    Button {
                        accept()
                    } label: {
                        HStack(spacing: 6) {
                            if isWorking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.seal")
                            }
                            Text(isWorking ? "Accepting…" : "Accept now")
                                .fontWeight(.semibold)
                        }
                        .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || isWorking)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(ActionColors.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The manual route, for anyone who prefers Terminal.
            VStack(alignment: .leading, spacing: 8) {
                Text("Or run this in Terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    Text(command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Then click Refresh in ForgedBrew.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("I’ll do this later") {
                isPresented = false
            }
            .buttonStyle(OutlinedButtonStyle())
            .foregroundStyle(.secondary)
            .disabled(isWorking)
        }
        .padding(28)
        .frame(width: 440)
    }

    private func accept() {
        guard !password.isEmpty, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            let failure = await appData.acceptXcodeLicense(password: password)
            isWorking = false
            if let failure {
                errorMessage = failure
            } else {
                password = ""
                isPresented = false
            }
        }
    }

    private func copyCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}

// MARK: - BrewErrorBanner
// Top-of-window notice for any brew read that failed for a reason OTHER than
// the Xcode license (which gets the sheet above). Until 2.4.8 the failure text
// was stored in AppDataService.lastError and never displayed anywhere, so a
// broken brew looked like an app with nothing installed. Shows brew's own
// words, dismissable; cleared automatically by the next successful read.
struct BrewErrorBanner: View {
    @Environment(AppDataService.self) private var appData

    var body: some View {
        if let message = appData.lastError, !appData.xcodeLicenseRequired {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ActionColors.update)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Homebrew reported a problem")
                        .font(.system(size: 12, weight: .semibold))
                    Text(message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button {
                    appData.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
            .padding(12)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
