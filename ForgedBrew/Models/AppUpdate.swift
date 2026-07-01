import Foundation

// MARK: - Non-Homebrew App Updates model
//
// Models for the "Mac Store/Other Apps" screens — apps Homebrew doesn't manage.
// We detect an available update from three sources:
//   • Sparkle   — app ships an SUFeedURL; fetch its appcast, compare the newest
//                 published version against the installed CFBundleShortVersionString.
//   • GitHub    — feed/homepage points at a repo; read the latest release tag.
//   • App Store — app carries a _MASReceipt. Reading the available version needs
//                 the `mas` CLI; without it we still list the app, just with no target.
//
// We don't update these apps in place — the screens are awareness-only, so the
// user opens the app (or the App Store) to update it. Why: see the dormant
// topgrade note in AppDataService.
//
// All types are nonisolated to cross the detection actor → @MainActor boundary
// (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).

// Where we detected the update. Drives the row's source badge.
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

    // The Homebrew cask that provides this app, if the catalog has a match.
    // Drives the row's "Adopt" button (hand the app to Homebrew). nil when no
    // cask matches. Defaulted so existing call sites stay source-compatible.
    var suggestedToken: String? = nil

    // Mac App Store product id (adamID) from `mas`, when known. Used to deep-link
    // to the app's store page (macappstore://apps.apple.com/app/id<storeID>).
    // nil for non-store apps, or store apps mas had no id for.
    var storeID: String? = nil

    // True when a cask matches, so the row can offer Adopt (hand it to Homebrew).
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
// Versions in the wild are messy: "26.084.0504", "1.4.3", "2.0.1 (4521)". We
// compare the dotted numeric components left-to-right and ignore trailing junk.
// Total (never throws); when a side won't parse we fall back to string
// inequality, so a differing version still surfaces rather than hiding.
//
// This burned me twice (see AppVersion.isNewer) — covered by AppVersionTests.
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
        // Marketing equal. A build number breaks the tie only when BOTH sides
        // have one; an asymmetric suffix ("2.0.1 (4521)" vs "2.0.1") is the same
        // version — otherwise a build-tagged rebuild masquerades as an update.
        if let ab = a.build, let bb = b.build { return ab > bb }
        return false
    }
}
