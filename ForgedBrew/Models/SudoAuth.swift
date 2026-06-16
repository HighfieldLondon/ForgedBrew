import Foundation

// A queued request for the user's administrator password, raised when an
// install/upgrade/uninstall targets a cask that requires root (it ships a
// `pkg` installer) or when brew emits a `Password:` prompt at runtime. The
// shared install manager publishes one of these so a view can present the
// password sheet; once the user provides a password the manager resumes the
// queued operation. nonisolated/Sendable so it can cross the actor boundary.
//
// Security model: the password is held in memory ONLY for the lifetime of the
// running app session (see AppDataService.sessionSudoPassword). It is never
// written to disk or the Keychain, and is wiped when ForgedBrew quits, so the
// first privileged update after a relaunch always re-prompts.
nonisolated struct SudoRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let token: String          // package token (e.g. "microsoft-word")
    let displayName: String    // pretty name for the sheet ("Microsoft Word")
    let isFormula: Bool
    let isUpgrade: Bool
    let zap: Bool              // only meaningful for uninstall
    let kind: Kind
    // True when this request backs an awaiting continuation (the Update-All
    // flow) rather than a queued single-package operation. Determines whether a
    // cancel must still release the resume closure (continuations would
    // otherwise hang forever).
    var isContinuation: Bool = false

    enum Kind: Equatable, Sendable {
        case install
        case uninstall
    }

    // Turns a brew token like "microsoft-word" into "Microsoft Word" for display
    // in the password sheet. Mirrors InstalledRowView.displayName so the sheet
    // and the row agree, but lives here so the model layer has no View dependency.
    static func prettyName(for token: String) -> String {
        token
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
