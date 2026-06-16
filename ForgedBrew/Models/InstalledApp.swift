import Foundation

// MARK: - Installed (non-Homebrew) app inventory model
//
// The Mac Store / Other Apps screen lists EVERY installed non-Homebrew app —
// not just the ones with a pending update — grouped into two categories and,
// within each, split into "Updates available" and "All apps" (mirroring the
// Homebrew Updates screen: outdated at the top, the full installed list below).
//
// An InstalledApp pairs a discovered app bundle with the AppUpdate that the
// scanner found for it (if any). `update == nil` means we either couldn't find
// a newer version or couldn't assess it — the row shows "Up to date".

// Which list an installed app belongs to in the segmented Mac Store / Other
// Apps control. App Store apps (a _MASReceipt is present) are "Mac Store";
// everything else (Sparkle / GitHub / Homebrew-cask / direct download) is
// "Other Apps".
nonisolated enum AppCategory: String, Sendable, Hashable, CaseIterable, Identifiable {
    case macStore
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macStore: return "Mac Store"
        case .other:    return "Other Apps"
        }
    }
}

// The segmented control on the Mac Store / Other Apps screen. "All" is a
// view-only filter that combines both storage categories; it is NOT a value an
// InstalledApp can carry (apps are always classified macStore or other).
nonisolated enum AppCategoryFilter: String, Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case macStore
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:      return "All"
        case .macStore: return "Mac Store"
        case .other:    return "Other Apps"
        }
    }

    // The single storage category this filter maps to, or nil for "All".
    var category: AppCategory? {
        switch self {
        case .all:      return nil
        case .macStore: return .macStore
        case .other:    return .other
        }
    }
}

nonisolated struct InstalledApp: Identifiable, Sendable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let appPath: String
    let category: AppCategory
    let installedVersion: String
    // The detected update for this app, if any. nil → up to date / not assessable.
    let update: AppUpdate?
    // On-disk size of the .app bundle in bytes, when measured. nil = unmeasured.
    let sizeBytes: Int64?
    // When the .app bundle was installed, derived from the bundle's filesystem
    // date (creation date, falling back to modification date). Non-Homebrew apps
    // carry no brew timestamp, so this is our best "installed" proxy. nil =
    // unknown/unmeasured.
    let installedDate: Date?
    // The Homebrew cask token that provides this app, when one exists in the
    // cask catalog (matched by app file name / display name). Drives the inline
    // "Adopt" button: present == adoptable, nil == no matching cask. This is the
    // same match the update probe uses, so the Installed list and the Updates
    // section agree on what's adoptable.
    let suggestedToken: String?
    // The app's homepage / download URL from the matching cask, when known.
    // Drives the "Website" button so the user can grab a new version manually
    // even when no in-place update path exists. nil == no known URL.
    let websiteURL: URL?

    var hasUpdate: Bool { update != nil }

    // True when Homebrew has a cask for this app, so it can be adopted (handed
    // to Homebrew for future management/updates).
    var isAdoptable: Bool { suggestedToken != nil }

    // Human-readable size like "148 MB" / "3.6 GB", or nil when unmeasured.
    var sizeDisplay: String? {
        guard let sizeBytes else { return nil }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: sizeBytes)
    }

    // Medium-style install date like "Jun 1, 2026", or nil when unknown. Matches
    // the formatting used for Homebrew packages so the date reads identically
    // across the Installed / Updates / Mac Store screens.
    var dateDisplay: String? {
        guard let installedDate else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: installedDate)
    }
}
