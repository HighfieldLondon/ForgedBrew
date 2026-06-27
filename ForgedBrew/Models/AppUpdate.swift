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

    // The Homebrew cask token that provides this app, when the cask catalog
    // has a match (homebrewCask-sourced updates always do). Drives the row's
    // "Adopt" button so the user can hand the app to Homebrew for future
    // management instead of relying on a (failing) in-place update. nil ==
    // no matching cask (e.g. Sparkle/GitHub/App Store apps with no cask).
    // Defaulted so existing call sites stay source-compatible.
    var suggestedToken: String? = nil

    // Mac App Store numeric product id (adamID), when known from `mas`. Lets us
    // (a) attempt a silent `mas upgrade <id>` and (b) deep-link straight to this
    // app's App Store page (macappstore://apps.apple.com/app/id<storeID>) if the
    // silent upgrade fails. nil for non-store apps, or store apps mas couldn't
    // give an id for.
    var storeID: String? = nil

    // True when a Homebrew cask exists for this app, so the row can offer an
    // Adopt action (hand it to Homebrew) in place of a dead in-place update.
    var isAdoptable: Bool { suggestedToken != nil }

    // True when we have a concrete newer version than what's installed. App Store
    // apps with an unknown available version are surfaced separately (the store
    // will no-op if already current); this getter only reports a parsed compare.
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
    // A version split into its MARKETING components (the dotted numbers users
    // think of as the version) and an optional trailing BUILD number. The build
    // is whatever follows the FIRST build separator — a space, "(", or "+":
    //   "2.0.1"        → marketing [2,0,1], build nil
    //   "2.0.1 (4521)" → marketing [2,0,1], build 4521
    //   "1.4.3+101"    → marketing [1,4,3], build 101
    // Keeping them separate is what lets us tell a real PATCH release (2.0 →
    // 2.0.1: an extra MARKETING component) apart from a pure build-suffix bump
    // (2.0.1 → "2.0.1 (4521)"). If both were flattened into one numeric array
    // they'd be indistinguishable, and we'd either conjure a phantom update for
    // the build suffix or silently MISS the patch release.
    struct Parsed { var marketing: [Int]; var build: Int? }

    // The leading integer of a chunk, tolerating a single "v"/"V" prefix
    // ("v2" → 2). nil for a non-numeric chunk ("beta", "rc1"). An absurd digit
    // run is clamped to Int.max rather than silently overflowing to 0.
    private static func leadingInt(_ chunk: Substring) -> Int? {
        var body = chunk
        if let first = body.first, first == "v" || first == "V" { body = body.dropFirst() }
        var digits = ""
        for ch in body { if ch.isNumber { digits.append(ch) } else { break } }
        if digits.isEmpty { return nil }
        return Int(digits) ?? Int.max
    }

    static func parse(_ version: String) -> Parsed {
        // Marketing = everything up to the first build separator; the rest (if
        // any) is the build suffix.
        var marketingPart = Substring(version)
        var buildPart: Substring? = nil
        if let idx = version.firstIndex(where: { $0 == " " || $0 == "(" || $0 == "+" }) {
            marketingPart = version[version.startIndex..<idx]
            buildPart = version[version.index(after: idx)...]
        }
        var marketing: [Int] = []
        for chunk in marketingPart.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" }) {
            if let n = leadingInt(chunk) { marketing.append(n) }
        }
        var build: Int? = nil
        if let buildPart {
            for chunk in buildPart.split(whereSeparator: {
                $0 == "." || $0 == "-" || $0 == "_" || $0 == " " || $0 == "(" || $0 == ")" || $0 == "+"
            }) {
                if let n = leadingInt(chunk) { build = n; break }
            }
        }
        return Parsed(marketing: marketing, build: build)
    }

    // Retained for any caller that just wants the marketing numbers.
    static func numericComponents(_ version: String) -> [Int] { parse(version).marketing }

    // True when `candidate` is strictly newer than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parse(candidate)
        let b = parse(current)
        if a.marketing.isEmpty || b.marketing.isEmpty {
            // Can't parse one side numerically — fall back to "different means
            // newer" so we don't hide a real update behind an unparseable string.
            return candidate.compare(current, options: .caseInsensitive) != .orderedSame
        }
        // Compare the MARKETING components fully, padding the shorter side with 0,
        // so a genuine patch release with an extra component wins (2.0 < 2.0.1).
        let n = max(a.marketing.count, b.marketing.count)
        for i in 0..<n {
            let ai = i < a.marketing.count ? a.marketing[i] : 0
            let bi = i < b.marketing.count ? b.marketing[i] : 0
            if ai != bi { return ai > bi }
        }
        // Marketing versions are equal. A BUILD number breaks the tie ONLY when
        // BOTH sides carry one ("2.0.1 (4522)" > "2.0.1 (4521)"); an asymmetric
        // build suffix ("2.0.1 (4521)" vs "2.0.1") counts as the same version, so
        // a build-tagged release of an already-installed marketing version doesn't
        // masquerade as an update.
        if let ab = a.build, let bb = b.build { return ab > bb }
        return false
    }
}
