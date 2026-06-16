import Foundation

// MARK: - Non-Homebrew App Updates model
//
// ForgedBrew's "App Updates" sidebar surfaces updates for apps that are NOT managed
// by Homebrew — Mac App Store installs and direct-download apps — so the user
// can see everything that needs updating in one place and either Update (open
// the update) or Park it (hold the nudge), the same way the brew Updates screen
// works. This is our "App Updates" / "Third-Party App Updates" design outline
// (Sparkle update checking, appcast XML parsing, outdated MAS apps, and a
// persisted set of ignored app updates).
//
// We detect updates from three sources:
//   • Sparkle   — the app ships an SUFeedURL in its Info.plist; we fetch its
//                 appcast XML and compare the newest published version against
//                 the installed CFBundleShortVersionString.
//   • GitHub    — the app's feed/homepage points at a GitHub repo; we read the
//                 latest release tag.
//   • App Store — the app carries a _MASReceipt; it's a Mac App Store install.
//                 (Reading the "available" version needs the `mas` CLI; when mas
//                 isn't present we still list it and route Update to the App
//                 Store (our "mas not installed" behavior).)
//
// Because non-Homebrew apps can't be silently upgraded the way `brew upgrade`
// does, "Update" opens the update (App Store page / download URL) rather than
// installing in place.
//
// All types are nonisolated so they cross the detection actor → @MainActor view
// boundary under the project's SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.

// Where an app's update came from. Drives the row's source badge and what the
// Update button does.
nonisolated enum AppUpdateSource: String, Codable, Sendable, Hashable, CaseIterable {
    case sparkle
    case github
    case appStore
    case homebrewCask

    var displayName: String {
        switch self {
        case .sparkle:  return "Sparkle"
        case .github:   return "GitHub"
        case .appStore: return "App Store"
        case .homebrewCask: return "Homebrew"
        }
    }

    // SF Symbol used for the small source badge on each row.
    var symbol: String {
        switch self {
        case .sparkle:  return "sparkles"
        case .github:   return "shippingbox"
        case .appStore: return "bag"
        case .homebrewCask: return "shippingbox.fill"
        }
    }
}

// A detected available update for a single non-Homebrew app. `id` is the bundle
// identifier so a parked record (also keyed by bundle id) lines up 1:1.
nonisolated struct AppUpdate: Identifiable, Sendable, Hashable {
    var id: String { bundleID }
    let bundleID: String          // CFBundleIdentifier, e.g. "com.microsoft.OneDrive-mac"
    let appName: String           // bundle name without ".app", e.g. "OneDrive"
    let appPath: String           // absolute path to the .app bundle
    let source: AppUpdateSource
    let installedVersion: String  // CFBundleShortVersionString on disk
    // The newest version the source advertises. nil when we can detect the app
    // is updatable but can't read the available version (e.g. an App Store app
    // with no `mas` CLI present) — the row still shows and routes Update to the
    // store, it just can't show a "→ x.y.z" target.
    let availableVersion: String?
    // Where Update should send the user:
    //   • Sparkle/GitHub → the download / release URL.
    //   • App Store      → the macappstore:// or App Store product URL.
    let updateURL: URL?
    // Optional release-notes link (Sparkle releaseNotesLink / GitHub release).
    let releaseNotesURL: URL?

    // Mac App Store numeric product id (adamID), when known from `mas`. Lets us
    // (a) attempt a silent `mas upgrade <id>` and (b) deep-link straight to this
    // app's App Store page (macappstore://apps.apple.com/app/id<storeID>) if the
    // silent upgrade fails. nil for non-store apps, or store apps mas couldn't
    // give an id for. Defaulted so existing call sites stay source-compatible.
    // The Homebrew cask token that provides this app, when the cask catalog
    // has a match (homebrewCask-sourced updates always do). Drives the row's
    // "Adopt" button so the user can hand the app to Homebrew for future
    // management instead of relying on a (failing) in-place update. nil ==
    // no matching cask (e.g. Sparkle/GitHub/App Store apps with no cask).
    var suggestedToken: String? = nil

    var storeID: String? = nil

    // True when we have a concrete newer version than what's installed. App Store
    // apps with an unknown available version are treated as "possibly outdated"
    // and surfaced anyway (the store will no-op if already current).
    // True when a Homebrew cask exists for this app, so the row can offer an
    // Adopt action (hand it to Homebrew) in place of a dead in-place update.
    var isAdoptable: Bool { suggestedToken != nil }

    var hasKnownNewerVersion: Bool {
        guard let availableVersion else { return false }
        return AppVersion.isNewer(availableVersion, than: installedVersion)
    }
}

// MARK: - Park record for non-Homebrew apps
//
// The brew ParkedApp model is keyed by (token, PackageType) and persisted in the
// GRDB `parkedApps` table. Non-Homebrew apps have no brew token and aren't in
// that table, so they get their own lightweight park record keyed by bundle id
// and persisted in UserDefaults as an ignored-app-updates record
// rather than adding a DB migration. It reuses the SAME ParkType semantics as
// the brew Park feature so the UI and the "why park?" explainer stay consistent.
nonisolated struct ParkedAppUpdate: Codable, Sendable, Hashable, Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let parkType: ParkType
    let parkedAt: Date
    // The available version known at park time. Used by .untilNextVersion to
    // detect when a genuinely newer release ships.
    let parkedVersion: String?
    // Wall-clock expiry for .duration parks; nil otherwise.
    let expiresAt: Date?

    // Whether this park should auto-expire now (so the app re-enters the App
    // Updates list). Mirrors the brew Park auto-unpark sweep.
    //   • .duration        → expired once expiresAt passes.
    //   • .untilNextVersion → expired once a version newer than parkedVersion
    //                         is available.
    //   • .indefinite      → never auto-expires.
    func shouldAutoUnpark(latestAvailable: String?) -> Bool {
        switch parkType {
        case .indefinite:
            return false
        case .duration:
            guard let expiresAt else { return false }
            return Date() >= expiresAt
        case .untilNextVersion:
            guard let latestAvailable, let parkedVersion else { return false }
            return AppVersion.isNewer(latestAvailable, than: parkedVersion)
        }
    }
}

// MARK: - Lightweight version comparison
//
// App versions in the wild are messy: "26.084.0504", "1.4.3", "2.0.1 (4521)",
// build-only strings, etc. We compare the dot-separated numeric components
// left-to-right, ignoring any non-numeric trailing junk. This is intentionally
// simple and total (never throws); when two versions aren't cleanly comparable
// we fall back to a case-insensitive string inequality so a differing version
// still reads as "an update is available" rather than silently hiding it.
nonisolated enum AppVersion {
    // Splits a version string into its leading numeric components. "2.0.1 (4521)"
    // → [2, 0, 1]; "v1.4.3" → [1, 4, 3]; "26.084.0504" → [26, 84, 504].
    static func numericComponents(_ version: String) -> [Int] {
        var comps: [Int] = []
        // Split on "." and the common build separators, then take the leading
        // integer of each chunk (so "0504" → 504, "1+build" → 1).
        let chunks = version.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" || $0 == " " })
        for chunk in chunks {
            var digits = ""
            for ch in chunk {
                if ch.isNumber { digits.append(ch) } else { break }
            }
            if digits.isEmpty {
                // A non-numeric chunk (e.g. "beta"): stop — trailing tags don't
                // participate in the ordered numeric compare.
                break
            }
            comps.append(Int(digits) ?? 0)
        }
        return comps
    }

    // True when `candidate` is strictly newer than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numericComponents(candidate)
        let b = numericComponents(current)
        if a.isEmpty || b.isEmpty {
            // Can't parse one side numerically — fall back to "different means
            // newer" so we don't hide a real update behind an unparseable string.
            return candidate.compare(current, options: .caseInsensitive) != .orderedSame
        }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false  // equal
    }
}
