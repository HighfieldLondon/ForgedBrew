//
//  OrphanedPackage.swift
//  ForgedBrew
//
//  A formula that Homebrew installed only as a dependency of some other
//  package and that nothing installed now requires — `brew autoremove`'s
//  candidates. Keeping these around wastes disk space without giving you
//  anything, so ForgedBrew surfaces them in the Maintenance tab and lets you
//  remove them one at a time or all at once.
//
//  Authoritative source: `brew autoremove --dry-run`. We deliberately do NOT
//  reconstruct the orphan list from `brew leaves` math — Homebrew's own
//  resolver accounts for build-dependency and cask edge cases that simple
//  leaf arithmetic gets wrong, so we trust autoremove's verdict directly.
//

import Foundation

// One orphaned formula plus the context we show in the row. `nonisolated` +
// Sendable so it can cross the actor boundary from BrewCLIService (an actor)
// up to the @MainActor UI without isolation warnings under the project's
// MainActor-default isolation.
nonisolated struct OrphanedPackage: Identifiable, Sendable, Hashable {
    // The formula token is unique within `brew autoremove`'s output, so it
    // doubles as the stable identity.
    var id: String { token }

    // Homebrew formula token, e.g. "gettext". This is exactly what we pass to
    // `brew uninstall --formula <token>`.
    let token: String

    // Installed version string (e.g. "0.22.5"), best-effort from `brew list
    // --versions`. nil when it couldn't be read.
    let version: String?

    // On-disk size of this formula's keg in bytes, best-effort via `du`. nil
    // when it couldn't be measured. Drives the per-row size label and the
    // reclaimable total.
    let sizeBytes: Int64?

    // Absolute Cellar path of the installed keg, e.g.
    // "/opt/homebrew/Cellar/gettext". Used for sizing and so a curious user
    // could Reveal it in Finder. nil if it couldn't be resolved.
    let cellarPath: String?

    // Human-readable size for the row, e.g. "12.4 MB". Falls back to an em dash
    // when the size is unknown.
    var sizeString: String {
        guard let bytes = sizeBytes else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// The result of one orphan scan: the packages plus a precomputed reclaimable
// total so the UI doesn't have to re-sum on every redraw.
nonisolated struct OrphanScanResult: Sendable, Hashable {
    let packages: [OrphanedPackage]

    // Sum of every package's known size in bytes. Packages with an unknown
    // size contribute nothing (so this is a lower bound, which is the safe
    // direction for a "you'll reclaim at least…" claim).
    var totalReclaimableBytes: Int64 {
        packages.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    // Human-readable reclaimable total, e.g. "48.2 MB". Empty-safe.
    var totalReclaimableString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalReclaimableBytes)
    }

    var isEmpty: Bool { packages.isEmpty }

    static let empty = OrphanScanResult(packages: [])
}
