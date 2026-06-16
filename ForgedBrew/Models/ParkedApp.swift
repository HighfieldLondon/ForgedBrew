import Foundation

// MARK: - Park (a.k.a. "hold an update") model
//
// "Parking" an installed package puts it in a holding area: ForgedBrew stops
// offering it in the Updates list and excludes it from "Update All" / "Upgrade
// All" so brew never tries to upgrade (and thus can't downgrade or clobber) it.
// We KEEP tracking the package, so the Parked view can still surface "a newer
// Homebrew version is available" and let the user Unpark + update when ready.
//
// Two motivating reasons (mirrors the two cases in the handoff doc):
//   1. The locally installed version is NEWER than Homebrew's (the `claude`
//      cask case — a directly-downloaded build is ahead of the brew cask), so
//      letting brew "upgrade" would actually downgrade it.
//   2. The user deliberately wants to hold an older version for a while.
//
// This is ForgedBrew's "Park" feature. The model has a park type
// { untilNextVersion, duration } plus parkedAt / parkedVersion /
// expiresAt, and we surface an explicit "why you'd do this" explainer in the
// sidebar Parked view.
//
// nonisolated so these value types can cross the DB actor → @MainActor view
// boundary under the project's SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.

// How long a park lasts before the package re-enters the normal Updates flow.
nonisolated enum ParkType: String, Codable, Sendable, CaseIterable, Hashable {
    // Stays parked until the user explicitly Unparks. Covers "hold an older
    // version indefinitely" and the Claude (local-newer-than-brew) case.
    case indefinite
    // Re-surfaces automatically when Homebrew ships a version newer than the
    // one recorded at park time (parkedVersion). Good for "skip this update,
    // but tell me about the next one".
    case untilNextVersion
    // Re-surfaces automatically once a wall-clock expiry passes (expiresAt).
    case duration

    var displayName: String {
        switch self {
        case .indefinite:      return "Indefinitely"
        case .untilNextVersion: return "Until next version"
        case .duration:        return "For a set time"
        }
    }

    var symbol: String {
        switch self {
        case .indefinite:       return "pause.circle"
        case .untilNextVersion: return "arrow.triangle.2.circlepath"
        case .duration:         return "clock"
        }
    }
}

// A parked package record. Persisted in the `parkedApps` table keyed by
// (token, type). `parkedVersion` is the Homebrew "current" version known at the
// time of parking, used to detect when a genuinely newer release ships (for the
// .untilNextVersion type and for the "update available" hint in the list).
nonisolated struct ParkedApp: Identifiable, Sendable, Hashable {
    let token: String
    let type: PackageType
    let parkType: ParkType
    let parkedAt: Date
    // The Homebrew latest/current version recorded at park time. nil if the
    // package wasn't outdated when parked (parked purely to hold it).
    let parkedVersion: String?
    // Wall-clock expiry for .duration parks; nil otherwise.
    let expiresAt: Date?

    // Identity is per (token, type) so a cask and formula with the same token
    // never collide.
    var id: String { "\(type.rawValue):\(token)" }
}

// MARK: - Park duration presets
//
// The fixed-length options offered in the "For a set time" picker. Each maps to
// a number of seconds added to `Date()` to compute `expiresAt`.
nonisolated enum ParkDuration: String, CaseIterable, Sendable, Hashable {
    case oneDay   = "1 day"
    case oneWeek  = "1 week"
    case oneMonth = "1 month"

    var seconds: TimeInterval {
        switch self {
        case .oneDay:   return 24 * 3600
        case .oneWeek:  return 7 * 24 * 3600
        case .oneMonth: return 30 * 24 * 3600
        }
    }
}
