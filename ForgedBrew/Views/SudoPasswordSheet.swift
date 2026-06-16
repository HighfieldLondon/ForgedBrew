import SwiftUI

// MARK: - SudoPasswordSheet
//
// Native admin-password prompt shown when an install/upgrade/uninstall targets
// a cask that requires root (it ships a `pkg` installer — e.g. Microsoft
// Office). ForgedBrew passes the password to brew via a SUDO_ASKPASS helper so the
// privileged step runs non-interactively instead of hanging on a `Password:`
// prompt that has no terminal.
//
// Security model: the password is held in memory ONLY for the
// running session — reused so the user types it once per launch, and wiped when
// ForgedBrew quits. It is never written to disk or the Keychain. The sheet states
// this plainly so the user understands what happens to it.
//
// Layout follows the other sheets: a single definite frame, no GeometryReader.
struct SudoPasswordSheet: View {
    let request: SudoRequest
    // Validates the entered password against `sudo` BEFORE we accept it, so a
    // wrong password can never be cached and silently let an operation proceed
    // (the bug where mistyped passwords "still worked" for apps that don't
    // actually invoke sudo). Returns true when the password is accepted.
    let validate: (String) async -> Bool
    // Called with the VALIDATED password on confirm, or nil on cancel.
    let onSubmit: (String?) -> Void

    @State private var password = ""
    @State private var isVerifying = false
    @State private var showWrongPassword = false
    @FocusState private var fieldFocused: Bool

    private var actionVerb: String {
        switch request.kind {
        case .install:   return request.isUpgrade ? "update" : "install"
        case .uninstall: return "remove"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 360)
        .onAppear { fieldFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Administrator Password Required")
                    .font(.system(size: 15, weight: .semibold))
                Text("To \(actionVerb) \(request.displayName)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Some apps install with a macOS package that needs administrator privileges. Enter your Mac login password so ForgedBrew can finish the \(actionVerb).")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 428, alignment: .leading)

            SecureField("Mac password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .frame(width: 428)
                .disabled(isVerifying)
                .onSubmit(submit)
                .onChange(of: password) { _, _ in
                    // Clear the error the moment the user edits the field.
                    if showWrongPassword { showWrongPassword = false }
                }

            // Inline incorrect-password feedback (re-prompt in place rather than
            // accepting a bad password and failing the operation later).
            if showWrongPassword {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(width: 14)
                    Text("That password was not accepted. Please try again.")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 428, alignment: .leading)
            }

            // Reassurance about exactly what happens to the password.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .frame(width: 14)
                Text("Kept in memory for this session only, so you won't be asked again until you quit ForgedBrew. It is never written to disk or your Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 428, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isVerifying {
                ProgressView()
                    .controlSize(.small)
                Text("Verifying…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                onSubmit(nil)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isVerifying)

            Button("Continue") {
                submit()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(password.isEmpty || isVerifying)
        }
        .padding(16)
    }

    private func submit() {
        guard !password.isEmpty, !isVerifying else { return }
        isVerifying = true
        showWrongPassword = false
        Task {
            let ok = await validate(password)
            await MainActor.run {
                isVerifying = false
                if ok {
                    onSubmit(password)
                } else {
                    // Reject in place: clear the field, surface the error, and
                    // refocus so the user can immediately retry. The password is
                    // never handed back to the caller, so it can't be cached.
                    showWrongPassword = true
                    password = ""
                    fieldFocused = true
                }
            }
        }
    }
}
