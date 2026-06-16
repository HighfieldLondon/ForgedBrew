//
//  GatekeeperRisk.swift
//  ForgedBrew
//
//  A Homebrew-managed cask app that macOS Gatekeeper currently REJECTS, and
//  that is therefore at risk from an upcoming Homebrew change.
//
//  The change: Homebrew is removing the `--no-quarantine` option for casks and,
//  as of September 1, 2026, is ending support for any cask that fails Gatekeeper
//  checks. Today Homebrew quietly works around the "downloaded from the
//  internet" quarantine flag during install/upgrade; once that goes away, an app
//  that Gatekeeper won't accept on its own will hit the "can't be opened"
//  wall. See Homebrew/brew#20755 (closed via #20973).
//
//  ForgedBrew surfaces those at-risk apps PROACTIVELY in the Maintenance tab's
//  Trust Maintenance card so the user can clear the quarantine flag now, on the
//  apps they trust, rather than discovering the breakage later. The trust action
//  is the same one macOS documents: `xattr -d com.apple.quarantine <app>` (no
//  sudo), which BrewCLIService.removeQuarantine(at:) already runs.
//
//  Authoritative signal: `spctl --assess --type execute` (the exact check
//  Gatekeeper performs at launch). We reuse BrewCLIService.scanAppSecurity, so a
//  risk here is the same verdict the Security Scan would show — we just filter
//  to the apps that would actually break.
//

import Foundation

// One installed cask app that Gatekeeper would reject today. `nonisolated` +
// Sendable so it can cross the actor boundary from BrewCLIService (an actor) up
// to the @MainActor UI without isolation warnings under the project's
// MainActor-default isolation.
nonisolated struct GatekeeperRisk: Identifiable, Sendable, Hashable {
    // The .app bundle path is unique per installed app, so it doubles as the
    // stable identity and is exactly what we pass to `xattr -d` to clear the
    // quarantine flag.
    var id: String { appPath }

    // Homebrew cask token, e.g. "google-chrome". Shown for context.
    let token: String

    // Human-facing app name from the bundle, e.g. "Google Chrome".
    let appName: String

    // Absolute path to the .app bundle, e.g. "/Applications/Google Chrome.app".
    // Used for Reveal in Finder and as the target of the trust action.
    let appPath: String

    // Why Gatekeeper rejects it, in plain language, derived from the security
    // scan. Lets the user judge whether they trust the app before clearing the
    // flag (e.g. "Unsigned", "Not notarized", "Signature invalid").
    let reason: String

    // The signing authority string, when present (e.g. "Developer ID
    // Application: Foo Bar (ABCDE12345)"). nil for unsigned apps. Extra context
    // shown beneath the app name.
    let signingAuthority: String?
}

// Translates a rejected AppSecurityResult into the plain-language reason shown
// in the Trust Maintenance row. Kept here (not in the View) so the wording is
// testable and lives next to the model it describes.
nonisolated enum GatekeeperRiskReason {
    static func describe(codesignValid: Bool,
                         teamIdentifier: String?,
                         notarized: Bool,
                         signingAuthority: String?) -> String {
        if signingAuthority == nil || signingAuthority?.isEmpty == true {
            return "Unsigned — macOS can’t verify who made it"
        }
        if !codesignValid {
            return "Signature invalid or tampered"
        }
        if (teamIdentifier?.isEmpty ?? true) {
            return "No Developer ID — not from an identified developer"
        }
        if !notarized {
            return "Not notarized by Apple"
        }
        return "Gatekeeper rejects this app"
    }
}

// The result of one Trust Maintenance scan: the at-risk apps plus when it ran,
// so the UI doesn't recompute on every redraw.
nonisolated struct GatekeeperRiskScanResult: Sendable, Hashable {
    let risks: [GatekeeperRisk]
    let scannedAt: Date

    var isEmpty: Bool { risks.isEmpty }
    var count: Int { risks.count }

    static let empty = GatekeeperRiskScanResult(risks: [], scannedAt: .distantPast)
}
