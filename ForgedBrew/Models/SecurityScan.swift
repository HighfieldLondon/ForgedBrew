//
//  SecurityScan.swift
//  ForgedBrew
//
//  The data model for the Diagnostics / Security Scan feature. When the user
//  runs a scan, ForgedBrew inspects every cask-installed app bundle on disk and
//  asks macOS's own security tooling four questions about each one:
//
//    1. Code signature  — is the bundle signed and does the signature still
//                          verify against what's on disk? (`codesign --verify`)
//    2. Signing identity — WHO signed it (the Developer ID authority + Team ID)?
//                          (`codesign -dv --verbose=2`)
//    3. Notarization     — did Apple notarize it and is the ticket stapled to
//                          the bundle? (Notarization Ticket line)
//    4. Gatekeeper       — would macOS actually allow it to launch right now?
//                          (`spctl --assess --type execute`)
//
//  These are the same checks Gatekeeper runs the first time you open an app, so
//  a "passed" result means the app is signed by an identifiable developer,
//  notarized by Apple, and accepted by your system's launch policy. A "failed"
//  result doesn't necessarily mean malware — an app can be unsigned or
//  un-notarized for benign reasons — but it tells the user exactly which of
//  these guarantees is missing so they can decide whether to trust it.
//
//  Everything here is `nonisolated` + Sendable and free of SwiftUI so it can
//  cross from the BrewCLIService actor up to the @MainActor UI. Any color the
//  UI needs is expressed as a ColorToken (defined in DiskFootprint.swift) that
//  the view maps to a concrete Color.
//

import Foundation

// MARK: - What the scan checks for (user-facing explanation)
//
// A single source of truth for the human-readable description of each check.
// The Security Scan sheet renders this list so the user always knows exactly
// what the scan is inspecting before and after they run it.
nonisolated struct SecurityCheckInfo: Identifiable, Sendable, Hashable {
    var id: String { title }
    let title: String
    let detail: String

    // The four checks every scanned app is put through, in the order shown.
    static let all: [SecurityCheckInfo] = [
        SecurityCheckInfo(
            title: "Code signature",
            detail: "Confirms the app is cryptographically signed and the signature still matches the files on disk, so you know it hasn't been tampered with or corrupted since the developer shipped it."
        ),
        SecurityCheckInfo(
            title: "Signing identity",
            detail: "Identifies the Apple Developer ID and Team ID that signed the app, so you can see exactly which company or developer it came from."
        ),
        SecurityCheckInfo(
            title: "Apple notarization",
            detail: "Checks whether Apple has notarized the app — meaning Apple scanned it for known malware — and that the notarization ticket is stapled to the bundle."
        ),
        SecurityCheckInfo(
            title: "Gatekeeper",
            detail: "Asks macOS whether it would allow the app to launch under your current security policy. This is the same verdict Gatekeeper gives the first time you open an app."
        )
    ]
}

// MARK: - Per-check verdict

// The state of one individual check on one app. `.notApplicable` covers cases
// where a check legitimately doesn't apply (e.g. an Apple system-signed binary
// is "Apple System" rather than a notarized Developer ID app).
nonisolated enum SecurityCheckStatus: String, Sendable, Hashable {
    case pass
    case warn
    case fail
    case notApplicable

    var tint: ColorToken {
        switch self {
        case .pass:          return .green
        case .warn:          return .yellow
        case .fail:          return .red
        case .notApplicable: return .gray
        }
    }

    // SF Symbol name for the row badge.
    var symbol: String {
        switch self {
        case .pass:          return "checkmark.circle.fill"
        case .warn:          return "exclamationmark.triangle.fill"
        case .fail:          return "xmark.circle.fill"
        case .notApplicable: return "minus.circle.fill"
        }
    }
}

// MARK: - Per-app result

nonisolated struct AppSecurityResult: Identifiable, Sendable, Hashable {
    var id: String { token }

    // The cask token (e.g. "bitwarden") and the human-facing app name derived
    // from the bundle (e.g. "Bitwarden").
    let token: String
    let appName: String
    // Absolute path of the .app bundle that was scanned (for Reveal in Finder).
    let appPath: String

    // --- Raw findings, parsed from codesign / spctl output ---

    // Did `codesign --verify --deep --strict` succeed?
    let codesignValid: Bool
    // The signing authority, e.g. "Developer ID Application: Bitwarden Inc
    // (LTZ2PFU5D6)" or "Software Signing" for Apple's own binaries. nil if the
    // app is unsigned.
    let signingAuthority: String?
    // The 10-character Team Identifier, e.g. "LTZ2PFU5D6". nil for unsigned or
    // Apple-system binaries (which have no Team ID).
    let teamIdentifier: String?
    // Was a notarization ticket found stapled to the bundle?
    let notarized: Bool
    // Did Gatekeeper (`spctl --assess --type execute`) accept the app?
    let gatekeeperAccepted: Bool
    // Gatekeeper's source classification, e.g. "Notarized Developer ID" or
    // "Apple System". nil if spctl produced no source line.
    let gatekeeperSource: String?
    // True when this is an Apple-signed system binary rather than a third-party
    // Developer ID app (changes how we phrase notarization, which doesn't apply
    // to Apple's own signed software).
    let isAppleSystem: Bool

    // Set when the scan itself failed to run for this app (e.g. the bundle
    // disappeared, or the tool errored). When non-nil the row is shown as an
    // error rather than a pass/fail.
    let scanError: String?

    // MARK: Derived per-check verdicts

    var signatureCheck: SecurityCheckStatus {
        if scanError != nil { return .warn }
        return codesignValid ? .pass : .fail
    }

    var identityCheck: SecurityCheckStatus {
        if scanError != nil { return .warn }
        if isAppleSystem { return .notApplicable }
        return (teamIdentifier?.isEmpty == false) ? .pass : .fail
    }

    var notarizationCheck: SecurityCheckStatus {
        if scanError != nil { return .warn }
        if isAppleSystem { return .notApplicable }
        return notarized ? .pass : .fail
    }

    var gatekeeperCheck: SecurityCheckStatus {
        if scanError != nil { return .warn }
        return gatekeeperAccepted ? .pass : .fail
    }

    // The overall verdict for the app, combining the individual checks.
    //   • pass  — Gatekeeper accepts it AND its signature is valid (system apps
    //             and notarized Developer ID apps both land here).
    //   • warn  — the scan couldn't complete, or it's signed/valid but missing
    //             notarization (unusual for a cask but not inherently unsafe).
    //   • fail  — Gatekeeper would reject it, or it's unsigned/tampered.
    var overall: SecurityCheckStatus {
        if scanError != nil { return .warn }
        if !gatekeeperAccepted || !codesignValid { return .fail }
        // Gatekeeper accepted + signature valid. Third-party apps should also be
        // notarized; flag (don't fail) if somehow not.
        if !isAppleSystem && !notarized { return .warn }
        return .pass
    }

    // The individual checks that did NOT pass, named for the user. Each entry is
    // a short phrase like "not notarized by Apple" so the summary can list every
    // problem an app has, not just the first one. notApplicable checks (e.g.
    // notarization on an Apple system binary) are correctly skipped.
    var failedCheckPhrases: [String] {
        var phrases: [String] = []
        if signatureCheck == .fail {
            phrases.append("signature missing or invalid")
        }
        if identityCheck == .fail {
            phrases.append("no identifiable developer (no Team ID)")
        }
        if notarizationCheck == .fail {
            phrases.append("not notarized by Apple")
        }
        if gatekeeperCheck == .fail {
            phrases.append("Gatekeeper would block it from launching")
        }
        return phrases
    }

    // A short, plain-language summary shown under the app name in the sheet. For
    // a flagged app it now lists EVERY check that didn't pass (capitalized first
    // word), so an app that fails several checks no longer collapses to just
    // one. Passing and inconclusive states keep their friendly one-liners.
    var summary: String {
        if let scanError { return "Couldn't scan: \(scanError)" }
        switch overall {
        case .pass:
            if isAppleSystem {
                return "Signed by Apple and accepted by Gatekeeper."
            }
            let who = teamIdentifier.map { " (Team \($0))" } ?? ""
            return "Signed, notarized, and accepted by Gatekeeper\(who)."
        case .warn:
            // A non-fatal state: signed/accepted but missing notarization, or a
            // scan that couldn't be fully verified. List specifics when we have
            // them, otherwise fall back to the friendly line.
            if !notarized && codesignValid && gatekeeperAccepted {
                return "Signed and accepted, but not notarized by Apple."
            }
            return "Signed, but verification was inconclusive."
        case .fail:
            // List every failing check, not just the first one.
            let phrases = failedCheckPhrases
            guard !phrases.isEmpty else {
                return "Couldn\u{2019}t verify this app\u{2019}s macOS security checks."
            }
            let joined = listPhrase(phrases)
            return "Couldn\u{2019}t verify: \(joined.prefix(1).uppercased())\(joined.dropFirst())."
        case .notApplicable:
            return ""
        }
    }

    // Joins phrases into "a", "a and b", or "a, b, and c".
    private func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head), and \(items.last!)"
        }
    }
}

// MARK: - Whole-scan result

nonisolated struct SecurityScanReport: Sendable, Hashable {
    let results: [AppSecurityResult]
    // When the scan was run, for the "Last scanned …" caption.
    let scannedAt: Date

    var passedCount: Int { results.filter { $0.overall == .pass }.count }
    var warnCount: Int   { results.filter { $0.overall == .warn }.count }
    var failedCount: Int { results.filter { $0.overall == .fail }.count }
    var totalCount: Int  { results.count }

    // Results sorted so problems float to the top: fail, then warn, then pass,
    // alphabetical within each group.
    var sortedResults: [AppSecurityResult] {
        func rank(_ s: SecurityCheckStatus) -> Int {
            switch s {
            case .fail: return 0
            case .warn: return 1
            case .pass: return 2
            case .notApplicable: return 3
            }
        }
        return results.sorted {
            let a = rank($0.overall), b = rank($1.overall)
            if a != b { return a < b }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    var isEmpty: Bool { results.isEmpty }

    // The overall headline verdict for the summary card.
    var headlineStatus: SecurityCheckStatus {
        if failedCount > 0 { return .fail }
        if warnCount > 0 { return .warn }
        if passedCount > 0 { return .pass }
        return .notApplicable
    }

    static let empty = SecurityScanReport(results: [], scannedAt: .distantPast)
}
