import Foundation
import SwiftUI

// Live state for a single install/uninstall operation owned by the shared
// install manager in AppDataService. Carried in `installProgress[token]` so
// any view (the detail card, a Home card) can render consistent progress
// regardless of which view started the operation.
nonisolated struct InstallProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing       // operation started, before brew emits a phase marker
        case needsPassword   // waiting for the user's admin password (sudo cask)
        case downloading     // brew is fetching/downloading the package
        case verifying       // brew is verifying the downloaded artifact
        case installing      // brew install/upgrade is running (pour/move/link)
        case removingOld     // brew is removing/backing up the previous version
        case cleaningUp      // post-install `brew cleanup` is running
        case uninstalling    // brew uninstall (optionally --zap) is running
        case finished        // completed successfully
        case failed(String)  // completed with an error (message attached)

        // True while an operation is in flight (i.e. not finished/failed).
        var isActive: Bool {
            switch self {
            case .preparing, .needsPassword, .downloading, .verifying, .installing,
                 .removingOld, .cleaningUp, .uninstalling:
                return true
            case .finished, .failed:
                return false
            }
        }

        // A short, user-facing label for the phase, shown under each app's row
        // while an operation is in flight (e.g. "Downloading…", "Installing…").
        var statusLabel: String {
            switch self {
            case .preparing:    return "Preparing…"
            case .needsPassword: return "Waiting for admin password…"
            case .downloading:  return "Downloading…"
            case .verifying:    return "Verifying download…"
            case .installing:   return "Installing…"
            case .removingOld:  return "Removing old version…"
            case .cleaningUp:   return "Cleaning up…"
            case .uninstalling: return "Uninstalling…"
            case .finished:     return "Done"
            case .failed:       return "Failed"
            }
        }

        // SF Symbol for the phase, for an icon next to the status label.
        var statusSymbol: String {
            switch self {
            case .preparing:    return "hourglass"
            case .needsPassword: return "lock.shield"
            case .downloading:  return "arrow.down.circle"
            case .verifying:    return "checkmark.shield"
            case .installing:   return "shippingbox"
            case .removingOld:  return "trash"
            case .cleaningUp:   return "sparkles"
            case .uninstalling: return "trash"
            case .finished:     return "checkmark.circle.fill"
            case .failed:       return "exclamationmark.triangle.fill"
            }
        }
    }
    var phase: Phase
    var log: [String]
    // True when this operation is an UNINSTALL (vs an install/upgrade). Lets the
    // UI word the success state correctly — "App is uninstalled" vs "App is
    // ready" — since the transient .finished phase carries no operation kind.
    var isUninstall: Bool = false
    // Optional operation verb ("Adopting", "Uninstalling", "Updating",
    // "Installing") shown while the operation is in flight so the row makes
    // clear WHAT it's doing, instead of the generic brew phase label. When
    // nil the UI falls back to the phase's own statusLabel.
    var verb: String? = nil

    // Convenience forwarders so existing callers using `progress.isActive`,
    // `progress.statusLabel`, `progress.statusSymbol` keep working unchanged.
    var isActive: Bool { phase.isActive }
    // Forward to the phase label, but word the success state for the operation
    // kind: an uninstall that finished should read "Uninstalled", not "Done"
    // (which reads like an install/upgrade). Failed/active phases are unchanged.
    var statusLabel: String {
        if case .finished = phase, isUninstall { return "Uninstalled" }
        // While the operation is still running, prefer the explicit verb so
        // the row reads "Adopting…" / "Uninstalling…" / "Updating…" instead
        // of a generic brew phase. Once a real brew phase arrives the verb
        // still wins for clarity; finished/failed use the phase wording.
        if phase.isActive, let verb { return verb + "\u{2026}" }
        return phase.statusLabel
    }
    var statusSymbol: String { phase.statusSymbol }

    // Maps a raw brew output line to the phase it signals, if any. brew prints
    // progress headers as `==> <Verb>…` (the `ohai` markers in brew's source).
    // Returns nil for lines that don't indicate a phase change so the caller
    // can leave the current phase untouched.
    static func phase(forLine line: String) -> Phase? {
        // Normalize: strip ANSI already handled upstream; find the marker body.
        guard let range = line.range(of: "==>") else { return nil }
        let body = line[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if body.hasPrefix("downloading") || body.hasPrefix("fetching") {
            return .downloading
        }
        if body.hasPrefix("verifying") {
            return .verifying
        }
        if body.hasPrefix("installing") || body.hasPrefix("pouring")
            || body.hasPrefix("moving") || body.hasPrefix("linking")
            || body.hasPrefix("upgrading") || body.hasPrefix("running") {
            return .installing
        }
        if body.hasPrefix("removing") || body.hasPrefix("purging")
            || body.hasPrefix("backing up") || body.hasPrefix("trashing")
            || body.hasPrefix("unlinking") {
            return .removingOld
        }
        return nil
    }
}

// A request to open the Adopt flow in Maintenance for a specific app, raised
// from a Mac App / Other Apps row's Adopt button. Identity uses a fresh UUID so
// the same app tapped twice still triggers SwiftUI onChange observers.
nonisolated struct AdoptNavigationRequest: Equatable, Identifiable {
    let id = UUID()
    let bundleID: String
    let appName: String
    let suggestedToken: String?
}

@MainActor
@Observable
final class AppDataService {
    static let shared = AppDataService()

    // Exposed state
    var isLoadingCasks: Bool = false
    var isLoadingFormulae: Bool = false
    var isLoadingInstalled: Bool = false
    // True once refreshInstalled() has completed at least one full load
    // this session. Section views (Installed, Homebrew Updates) use this
    // to AVOID re-running the brew CLI every time the user navigates into
    // them: the launch-time refreshEverything() (or a manual rescan / a
    // post-action auto-refresh) is the source of truth. The first-ever
    // appearance still triggers a load if the launch refresh hasn't landed
    // yet, so a fast click into a panel never shows a permanently empty list.
    var hasLoadedInstalledOnce: Bool = false
    var lastError: String? = nil
    var homebrewVersion: String = ""
    // True when Homebrew is not installed on this Mac. Set at launch from a
    // fast filesystem check (BrewCLIService.isInstalled). Drives the first-run
    // "install Homebrew" sheet — ForgedBrew is a Homebrew front-end, so without
    // brew there's nothing it can manage until the user installs it.
    var brewMissing: Bool = false

    // True while a full, app-wide refresh is in flight (launch refresh or the
    // global "rescan across the board"). Drives the non-blocking "Refreshing
    // your data…" overlay so the user knows work is happening in the background
    // and isn't confused by panels that haven't filled in yet. Cleared the
    // moment refreshEverything() finishes.
    var isRefreshingEverything: Bool = false

    // A request, raised from a Mac App / Other Apps row, to take the user to
    // the Adopt flow in Maintenance instead of adopting inline. The row sets
    // this; DetailRouter observes it to switch the sidebar to Maintenance, and
    // MaintenanceView observes it to open the Adopt sheet (pre-targeted at the
    // requested app). Carrying the bundleID lets the sheet highlight/scroll to
    // the right candidate. Bumped via a fresh value each time so repeated taps
    // on the same app still fire onChange. Cleared once consumed.
    var adoptNavigationRequest: AdoptNavigationRequest? = nil

    // Data — views read directly from these
    var casks: [CaskMetadata] = []
    var formulae: [FormulaMetadata] = []
    var installedPackages: [InstalledPackage] = []

    // Cached count of non-deprecated casks per top-level category. Recomputed
    // whenever `casks` changes (end of refreshCasks). Sidebar badges read this
    // instead of filtering the full catalog on every view update. Deprecated
    // casks are excluded (per product decision) so counts match the catalog the
    // user can actually browse.
    var categoryCounts: [CaskCategory: Int] = [:]

    // Cached count of non-deprecated casks per (category, subcategory). Keyed by
    // category, value maps subcategory display name → count. Powers the sidebar
    // disclosure children's counts. Built alongside categoryCounts.
    var subcategoryCounts: [CaskCategory: [String: Int]] = [:]

    // Total count of browsable (non-deprecated, non-disabled) formulae. Powers
    // the single "Formulae" sidebar category's badge. Recomputed at the end of
    // refreshFormulas.
    var formulaCount: Int = 0

    // Cached count of browsable formulae per subcategory display name (e.g.
    // "Languages & Runtimes" → 412). Formulae are a single-level taxonomy under
    // the one "Formulae" category, so this is a flat map (no outer category key).
    // Powers the Formulae sidebar disclosure children's counts.
    var formulaSubcategoryCounts: [String: Int] = [:]

    // Cached subcategory display name per formula token (e.g. "wget" ->
    // "Networking & Downloaders"). Classification is expensive, so we run it
    // ONCE per formula (in recomputeFormulaCounts) and read from this map
    // everywhere instead of calling FormulaClassifier.classify() on every
    // SwiftUI body evaluation. This is the key fix for slow Formulae scrolling.
    var formulaSubcategoryByToken: [String: String] = [:]

    // Scroll-position anchors for the Formulae browse grids, so returning from a
    // formula detail card lands back where the user left off (mirrors the cask
    // BrowseViews viewModel.scrollAnchorID/Subcategory). Stored here because
    // FormulaBrowseView is a plain struct with no dedicated view model and its
    // @State would reset on navigation. Set on tap, consumed + cleared on restore.
    var formulaScrollAnchorID: String? = nil
    var formulaScrollAnchorSubcategory: String? = nil

    // Convenience: quick lookup by token
    var installedByToken: [String: InstalledPackage] = [:]

    // MARK: - Shared install/uninstall manager
    //
    // Install and uninstall operations used to be driven by the view that
    // started them (DetailView's @State view model consuming the brew stream).
    // When the user navigated away, the view — and its consuming Task — were
    // torn down, which terminated the AsyncStream and cancelled the underlying
    // brew Process mid-install. To make installs survive navigation, the
    // singleton AppDataService now OWNS the operation: it holds a long-lived
    // Task per token (not tied to any view) that consumes the stream itself,
    // runs `brew cleanup` after a successful install, then refreshes installed
    // state app-wide. Views observe progress via `installProgress[token]`.

    // Live progress for in-flight (and just-finished) operations, keyed by
    // token. Views read this to render their HUD/button state. Finished/failed
    // entries are cleared a few seconds after completion.
    var installProgress: [String: InstallProgress] = [:]

    // A single install/uninstall operation surfaced for the app-wide centered
    // HUD (see ForgedBrewApp). Carries the token, a human display name, and the
    // live progress so the overlay can render the existing InstallHUD without
    // reaching into the dictionary itself.
    nonisolated struct ActiveInstallEntry: Equatable {
        let token: String
        let displayName: String
        let progress: InstallProgress
    }

    // The operation the app-wide centered HUD should display, if any. Prefers
    // an in-flight operation; if none is running but a just-finished/failed
    // entry is still present (it auto-clears a few seconds later), surface that
    // so the user sees the "Done"/"Failed" state before it fades. Returns nil
    // when nothing is installing/uninstalling.
    var activeInstallEntry: ActiveInstallEntry? {
        // In-flight first.
        if let pair = installProgress.first(where: { $0.value.phase.isActive }) {
            return ActiveInstallEntry(
                token: pair.key,
                displayName: displayName(forToken: pair.key),
                progress: pair.value
            )
        }
        // Otherwise a lingering finished/failed entry.
        if let pair = installProgress.first {
            return ActiveInstallEntry(
                token: pair.key,
                displayName: displayName(forToken: pair.key),
                progress: pair.value
            )
        }
        return nil
    }

    // A cheap Equatable key the app-root overlay animates on: it changes when
    // the surfaced token OR its phase changes, so the centered HUD appears,
    // updates, and dismisses with a smooth transition. Folding token + phase
    // into one string keeps the .animation(value:) trigger simple.
    var activeInstallKey: String {
        guard let e = activeInstallEntry else { return "" }
        return e.token + "|" + String(describing: e.progress.phase)
    }

    // Best-effort human name for a brew token, for the centered HUD headline.
    // Checks the loaded cask catalog, then the installed set, then the formula
    // catalog, and finally falls back to the raw token (still readable, e.g.
    // "clop"). Pure lookup — no I/O.
    func displayName(forToken token: String) -> String {
        if let cask = casks.first(where: { $0.token == token }) {
            return cask.displayName
        }
        if let formula = formulae.first(where: { $0.name == token }) {
            return formula.name
        }
        // installedByToken carries no pretty name (InstalledPackage has only a
        // token), so fall through to the raw token — still readable (e.g. "clop",
        // "wget"). The cask/formula catalogs above usually supply a nicer name.
        return token
    }

    // The long-lived Tasks backing each operation, keyed by token. Stored here
    // (on the singleton) rather than in a view so navigating away can't cancel
    // them. Presence in this dict == "an operation is in flight for this token".
    private var installTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Non-Homebrew app updates (topgrade)
    //
    // Live progress for in-flight (and just-finished) topgrade-driven app
    // updates, keyed by the app's bundle identifier. Kept SEPARATE from
    // installProgress (which is keyed by brew token) so the two never collide.
    // The "Mac & Other Apps" rows read this to render the same HUD the brew
    // Updates rows show. Finished/failed entries auto-clear a few seconds after
    // completion.
    var appUpdateProgress: [String: InstallProgress] = [:]

    // Backing Tasks for each in-flight app update, keyed by bundle id. Presence
    // == "an app update is running for this bundle id". The sentinel key
    // `AppDataService.allAppsUpdateKey` backs the header "Update All Apps" run.
    private var appUpdateTasks: [String: Task<Void, Never>] = [:]

    // Sentinel bundle-id key for the "Update All Apps" aggregate run.
    static let allAppsUpdateKey = "__forgedbrew_all_apps__"

    // Tokens whose post-finish auto-clear is managed by a batch operation
    // (Update Selected). For these, finish() does NOT schedule the usual
    // 4-second HUD clear — instead the batch keeps the row pinned on
    // "Cleaning up…" through the single shared `brew cleanup`, then clears it
    // itself when that cleanup completes. This stops a fast per-app upgrade
    // from fading its row before the shared cleanup step is even done.
    private var batchManagedClearTokens: Set<String> = []

    // MARK: - Sudo / admin password handling
    //
    // Some casks (those shipping a `pkg`, e.g. Microsoft Office) need root to
    // install/upgrade/uninstall. When we detect that, we publish a SudoRequest
    // here; a view presents the password sheet and calls provideSudoPassword.
    // The pending operation is queued in `queuedSudoOperations` until then.

    // The current outstanding admin-password request, or nil. Views observe this
    // to present the password sheet.
    var pendingSudoRequest: SudoRequest? = nil

    // Admin password held for the lifetime of THIS app session ONLY. It lives in
    // memory, is never written to disk or the Keychain, and is wiped when the
    // app terminates (the process dies, taking this with it) so the first
    // privileged update after a relaunch re-prompts. Within one session it is
    // reused so the user only types it once.
    private var sessionSudoPassword: String? = nil

    // Operations waiting on an admin password, keyed by SudoRequest id. Resumed
    // by provideSudoPassword once the user supplies (or cancels) the password.
    private var queuedSudoOperations: [UUID: () -> Void] = [:]

    // Whether the user has already entered their admin password this session
    // (so the password sheet can show "using your saved password for this
    // session" affordances if ever needed). Memory-only.
    var hasSessionSudoPassword: Bool {
        sessionSudoPassword != nil
    }

    // Validates an admin password against `sudo` before it is ever cached or
    // used to drive a brew operation. The SudoPasswordSheet calls this from its
    // Continue button so a wrong password is rejected in place and re-prompted,
    // rather than being cached and silently allowing the operation to proceed.
    func validateSudoPassword(_ password: String) async -> Bool {
        await cli.validateSudoPassword(password)
    }

    // True while an install/uninstall is running for the given token. Views use
    // this to disable buttons and avoid kicking off a duplicate operation.
    func isOperationInFlight(token: String) -> Bool {
        installTasks[token] != nil
    }

    // In-memory source of truth for the UI's favorite state. Seeded from the
    // favorites table at launch (loadFavorites) and kept in sync by
    // toggleFavorite, which also persists to the DB.
    var favoriteTokens: Set<String> = []
    // Combined count of the user's Notes & Tags screen: apps that carry a
    // note PLUS user-defined tags. Cached here (async DB reads) so the
    // sidebar can show the total synchronously. Refreshed by
    // loadNotesAndTagsCount() on launch and after edits.
    var notesAndTagsCount: Int = 0

    // MARK: - Taps (source repositories)
    //
    // The Homebrew taps the user has added (extra source repos beyond the
    // built-in core/cask catalogs). Seeded by loadTaps() on launch + refresh.
    // Drives the sidebar "Taps" row count and the Taps screen. Sorted with
    // third-party taps first (most relevant), official ones last.
    var taps: [Tap] = []

    // Sidebar count for the Taps row.
    var tapCount: Int { taps.count }

    // MARK: - Parked apps (in-memory state)
    //
    // In-memory source of truth for which packages are parked (updates held).
    // Seeded from the parkedApps table at launch + on refresh (loadParked) and
    // kept in sync by park()/unpark(), which also persist to the DB. The set is
    // keyed by the package id ("<type>:<token>", matching ParkedApp.id /
    // InstalledPackage.id) so a cask and formula sharing a token never collide.
    //
    // `parkedRecords` keeps the full ParkedApp rows (for the Parked view and the
    // expiry/until-next-version logic); `parkedIDs` is the cheap membership set
    // the Updates filter consults on every redraw.
    var parkedIDs: Set<String> = []
    var parkedRecords: [ParkedApp] = []

    // Deep-link coordinator. External entry points (a Spotlight result tap or the
    // OpenCaskIntent from Shortcuts/Siri) can't reach into the view hierarchy to
    // open a detail page directly, so they publish the requested package here.
    // DetailRouter observes it, resolves it to a CaskMetadata or FormulaMetadata,
    // opens the in-app detail page, and clears it back to nil. Staying in-app
    // (rather than launching the browser) matches the in-app-navigation rule.
    //
    // The request carries a `kind` so a Spotlight tap on an installed FORMULA
    // (id "formula:<name>") routes to the formula detail page instead of being
    // looked up only against the cask catalog (which silently no-ops). A bare
    // token from the cask-only OpenCaskIntent resolves as .unknown, which tries
    // casks first and then formulae.
    var pendingDeepLink: DeepLinkRequest? = nil

    // Identifies which catalog (cask vs formula) a deep-link target lives in.
    // .unknown means the source (e.g. the cask-only OpenCaskIntent) didn't say,
    // so the router tries casks first and then formulae.
    nonisolated enum DeepLinkKind: Equatable, Sendable {
        case cask
        case formula
        case unknown
    }

    // A pending request to open an in-app detail page, published by an external
    // entry point (Spotlight tap / OpenCaskIntent) and consumed by DetailRouter.
    // Equatable so DetailRouter can observe it with .onChange.
    nonisolated struct DeepLinkRequest: Equatable, Sendable {
        let token: String
        let kind: DeepLinkKind
    }

    // Publishes a deep-link request for a bare token (cask-only intents path).
    // Trims whitespace and ignores empties. Kind is .unknown so resolution tries
    // the cask catalog first, then falls back to formulae.
    func requestDeepLink(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingDeepLink = DeepLinkRequest(token: trimmed, kind: .unknown)
    }

    // Publishes a deep-link request from a Spotlight CSSearchableItem unique id,
    // which is formatted "cask:<token>" / "formula:<token>" (see SpotlightIndexer
    // + InstalledPackage.id). Preserves the type prefix as a DeepLinkKind so the
    // router opens the correct detail page.
    func requestDeepLink(spotlightID: String) {
        let kind: DeepLinkKind
        let token: String
        if let colon = spotlightID.firstIndex(of: ":") {
            let prefix = String(spotlightID[spotlightID.startIndex..<colon]).lowercased()
            token = String(spotlightID[spotlightID.index(after: colon)...])
            switch prefix {
            case "formula": kind = .formula
            case "cask": kind = .cask
            default: kind = .unknown
            }
        } else {
            token = spotlightID
            kind = .unknown
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingDeepLink = DeepLinkRequest(token: trimmed, kind: kind)
    }

    // References to the actor services (held by value — actors are reference types in Swift)
    let db: DatabaseManager = .shared
    let api: BrewAPIService = .shared
    let cli: BrewCLIService = .shared

    private init() {}

    // Runs refreshCasks, refreshInstalled, refreshAnalytics.
    // Each catches its own errors internally, so this is non-throwing.
    func refreshAll() async {
        // Installed state FIRST so Home cards and detail pages reflect the
        // user's real inventory the moment the window appears — independent of
        // the slower catalog network fetch. Previously this ran AFTER the cask
        // + formula catalog refreshes, which on a stale launch could take many
        // seconds, during which every app showed as "not installed" until the
        // user happened to open the Installed/Updates page. Loading installed +
        // favorites + parked up front (they're fast, local CLI/DB reads) fixes
        // the launch race so a full, correct picture is present immediately.
        await refreshInstalled()
        await loadFavorites()
        await loadParked()
        await loadNotesAndTagsCount()
        // Catalog + analytics can fill in behind the installed state; the cards
        // already have their installed badges by now.
        await refreshCasks()
        await refreshFormulas()
        await refreshAnalytics()
    }

    // Just the fast, local inventory work that fills the Installed, Homebrew
    // Updates, and Mac/Other-apps panels: the installed-package read (which also
    // carries the outdated flags that drive the Updates list) plus the Mac/other
    // app scan. These are independent (one is a brew CLI read, the other a
    // filesystem/mas scan), so they run CONCURRENTLY and BEFORE the slower
    // catalog/analytics network fetches — so all three panels are populated the
    // moment the window appears instead of waiting behind the catalog fetch.
    func refreshInventoryFast() async {
        async let installed: Void = refreshInstalled()
        async let macOther: Void = refreshAppUpdates()
        async let favorites: Void = loadFavorites()
        async let parked: Void = loadParked()
        async let notesTags: Void = loadNotesAndTagsCount()
        async let tapsLoad: Void = loadTaps()
        _ = await (installed, macOther, favorites, parked, notesTags, tapsLoad)
    }

    // The single app-wide refresh used by BOTH launch and the global
    // "rescan across the board" action. refreshAll() only covers Homebrew data
    // (installed/updates/catalog/analytics); the Mac App Store & other
    // (non-Homebrew) apps live in AppUpdateService and previously only updated
    // when the user navigated to the "Mac Store/Other Apps" page. That's the
    // root cause of Bug 4 — panels only refreshed lazily on first visit. This
    // method refreshes Homebrew data AND kicks the Mac/other-app scan so every
    // panel (Installed, Updates, Mac/Other apps, Parked, badges) reflects
    // reality right after launch and after any global rescan.
    //
    // Sets isRefreshingEverything around the whole run so the UI can show a
    // non-blocking "Refreshing your data…" indicator that clears on completion.
    func refreshEverything() async {
        // Coalesce overlapping global refreshes (e.g. launch + a manual rescan)
        // so the overlay flag and underlying work don't double-run.
        guard !isRefreshingEverything else { return }
        isRefreshingEverything = true
        // Always clear the flag, even if an awaited step is cancelled, so the
        // "Refreshing your data…" overlay can never get stuck on screen.
        defer { isRefreshingEverything = false }
        // Fill the three inventory panels (Installed, Homebrew Updates, Mac/Other
        // apps) FIRST and concurrently, so they're populated the instant the
        // window appears — not only after the user clicks into each one. The
        // slower catalog + analytics network fetches then fill in behind them.
        await refreshInventoryFast()
        await refreshCasks()
        await refreshFormulas()
        await refreshAnalytics()
    }

    // Rescans Mac App Store / other (non-Homebrew) apps for available updates,
    // excluding Homebrew-managed bundles (so brew casks aren't double-counted).
    // Mirrors AppUpdatesView.rescan() but lives here so launch + global rescan
    // can drive it without the view being on screen.
    func refreshAppUpdates() async {
        let managed = (try? await cli.installedCaskAppBundles()) ?? []
        let managedPaths = Set(managed.map {
            URL(fileURLWithPath: $0.appPath).resolvingSymlinksInPath().path
        })
        await AppUpdateService.shared.scan(managedAppPaths: managedPaths, casks: casks)
    }

    // MARK: - Adopt a non-Homebrew app

    // Hands a non-Homebrew app (App Store / direct download) to Homebrew via
    // `brew install --cask --adopt <token>`. Used by the inline "Adopt" button
    // on the Mac Store / Other Apps screen (both the Installed list and the
    // Updates section). Mirrors the Maintenance adopt flow: drive the adopt
    // stream, classify the output, and on a clean success re-scan so the app
    // moves out of the Other Apps lists and into Homebrew's managed inventory.
    //
    // Returns the structured outcome so the row can surface success/failure
    // without re-deriving it. Drives the per-app HUD via appUpdateProgress so
    // the row shows a spinner while brew works, consistent with in-place updates.
    @discardableResult
    func adoptOtherApp(token: String, bundleID: String, force: Bool = false) async -> AdoptOutcome {
        appUpdateProgress[bundleID] = InstallProgress(phase: .installing, log: [], verb: "Adopting")
        var lines: [String] = []
        let stream = await cli.adoptCask(token: token, force: force)
        for await line in stream {
            lines.append(line)
            appUpdateProgress[bundleID]?.log.append(line)
        }
        let outcome = MaintenanceMetrics.adoptSummary(lines)
        if outcome.isSuccess {
            appUpdateProgress[bundleID]?.phase = .finished
            // The app is now Homebrew-managed. Refresh the Homebrew inventory
            // AND re-scan Other Apps so the adopted app leaves the Other Apps
            // lists (it's excluded as a managed bundle) and appears under
            // Homebrew. Brief pause so the row's success state is visible first.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await refreshInventoryFast()
            await refreshAppUpdates()
            appUpdateProgress[bundleID] = nil
        } else {
            appUpdateProgress[bundleID]?.phase = .failed(outcome.message)
        }
        return outcome
    }

    // Convenience for the Home screen's manual Refresh button: re-fetches the
    // cask + formula catalogs and analytics, bypassing the 6-hour TTL when
    // force is true. Does NOT touch installed packages or favorites (Home is a
    // discovery/feed surface, not an inventory). Sequenced so the loading flags
    // (isLoadingCasks/isLoadingFormulae) flip in a predictable order.
    func refreshCatalog(force: Bool = false) async {
        await refreshCasks(force: force)
        await refreshFormulas(force: force)
        await refreshAnalytics()
    }

    // MARK: - Favorites

    // Seeds favoriteTokens from the favorites table. Safe to call on launch
    // and after data refreshes. Errors are swallowed (favorites are
    // non-critical) but recorded in lastError for debugging.
    func loadFavorites() async {
        do {
            favoriteTokens = try await db.fetchFavoriteTokens()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Recomputes the Notes & Tags sidebar total: number of apps with a saved
    // note plus the number of user-defined tags. Best-effort; errors leave
    // the previous count in place. Call after launch and after any note/tag
    // change so the sidebar badge stays accurate.
    func loadNotesAndTagsCount() async {
        do {
            let notes = try await db.fetchAllNotes()
            let tags = try await db.fetchTags()
            notesAndTagsCount = notes.count + tags.count
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Taps

    // Seeds `taps` from `brew tap-info --installed --json`. Best-effort; errors
    // leave the previous list in place and are recorded in lastError. Sorted
    // third-party-first, then alphabetically, so the user's own added taps lead.
    func loadTaps() async {
        do {
            let fetched = try await cli.tapInfos()
            taps = fetched.sorted { a, b in
                if a.official != b.official { return !a.official }   // third-party first
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // The user's INSTALLED packages that came from a given tap. Matched by
    // intersecting the tap's provided formula/cask identifiers with the
    // installed inventory. brew reports cask tokens fully-qualified for
    // third-party taps (e.g. "user/repo/token"), so we compare on the bare
    // leaf token as well to be robust across default vs tapped sources.
    func installedPackages(forTap tap: Tap) -> [InstalledPackage] {
        // Build a set of the leaf tokens this tap provides.
        let leafTokens = Set(tap.providedTokens.map { $0.split(separator: "/").last.map(String.init) ?? $0 })
        return installedPackages.filter { pkg in
            leafTokens.contains(pkg.token)
        }
    }

    // Removes a tap via `brew untap`. brew refuses if packages are still
    // installed from it (we never force), so installed apps are never deleted.
    // On success the tap drops out of `taps`. Returns brew's result so the UI
    // can surface the exact message on failure.
    @discardableResult
    func removeTap(_ name: String) async -> BrewCLIService.TapActionResult {
        let result = await cli.untap(name)
        if result.success {
            await loadTaps()
        }
        return result
    }

    // Returns true if the given token is currently favorited.
    func isFavorite(_ token: String) -> Bool {
        favoriteTokens.contains(token)
    }

    // Flips favorite state for a token: updates the in-memory set immediately
    // (so the UI reacts instantly via @Observable) then persists to the DB.
    // If the DB write fails, the in-memory change is rolled back.
    func toggleFavorite(token: String) async {
        let willFavorite = !favoriteTokens.contains(token)
        if willFavorite {
            favoriteTokens.insert(token)
        } else {
            favoriteTokens.remove(token)
        }
        do {
            try await db.markFavorite(token: token, isFavorite: willFavorite)
        } catch {
            // Roll back the optimistic UI change on failure.
            if willFavorite {
                favoriteTokens.remove(token)
            } else {
                favoriteTokens.insert(token)
            }
            lastError = error.localizedDescription
        }
    }

    // Fetches the full CaskMetadata for favorited casks (most recent first),
    // for the FavoritesView grid.
    func fetchFavoriteCasks() async -> [CaskMetadata] {
        do {
            return try await db.fetchFavorites()
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    // MARK: - Notes

    // Returns the saved note for a token, or "" if none. Used to seed an
    // editor with the current note text.
    func note(for token: String) async -> String {
        do {
            return try await db.fetchNote(token: token) ?? ""
        } catch {
            lastError = error.localizedDescription
            return ""
        }
    }

    // Persists a note for a token. An empty/whitespace note removes it
    // (DatabaseManager.saveNote deletes the row in that case).
    func saveNote(token: String, note: String) async {
        do {
            try await db.saveNote(token: token, note: note)
            await loadNotesAndTagsCount()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Returns all casks that have a note, as NotedCask rows (most recent
    // first), for the NotesView list.
    func fetchNotedCasks() async -> [NotedCask] {
        do {
            let pairs = try await db.fetchAllNotes()
            return pairs.map { pair in
                NotedCask(
                    token: pair.cask.token,
                    displayName: pair.cask.displayName,
                    note: pair.note
                )
            }
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    // MARK: - Tags
    //
    // Thin wrappers over DatabaseManager's tag store. The view layer talks only
    // to AppDataService; this keeps the DB actor off the UI and lets us resolve
    // tag memberships against the in-memory cask/formula catalogs (which live
    // here, not in the DB layer).

    // Returns every tag with its current item count, alphabetised. Drives the
    // Tags section of the Notes & Tags view and the tag picker on detail pages.
    func fetchTags() async -> [Tag] {
        do {
            return try await db.fetchTags()
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    // Returns the tags carried by a single package. Used to render the tag
    // chips on a detail page and to pre-check the picker.
    func tags(forToken token: String, type: PackageType) async -> [Tag] {
        do {
            return try await db.fetchTags(forToken: token, type: type)
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    // Creates a tag and returns it (with its assigned id), or nil on failure.
    @discardableResult
    func createTag(name: String, color: TagColor, icon: String) async -> Tag? {
        do {
            let tag = try await db.createTag(name: name, color: color, icon: icon)
            await loadNotesAndTagsCount()
            return tag
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // Updates a tag's name/color/icon in place (memberships preserved).
    func updateTag(id: Int64, name: String, color: TagColor, icon: String) async {
        do {
            try await db.updateTag(id: id, name: name, color: color, icon: icon)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Deletes a tag and all of its memberships.
    func deleteTag(id: Int64) async {
        do {
            try await db.deleteTag(id: id)
            await loadNotesAndTagsCount()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Attaches a tag to a package (idempotent).
    func addTag(tagId: Int64, token: String, type: PackageType) async {
        do {
            try await db.addTag(tagId: tagId, token: token, type: type)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Detaches a tag from a package (no-op if not attached).
    func removeTag(tagId: Int64, token: String, type: PackageType) async {
        do {
            try await db.removeTag(tagId: tagId, token: token, type: type)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Returns the packages carrying a tag, resolved against the in-memory cask
    // and formula catalogs into render-ready TaggedPackage rows (membership
    // order preserved — most-recently-tagged first). A reference whose package
    // is no longer in the catalog (e.g. removed from Homebrew) is skipped.
    func taggedPackages(tagId: Int64) async -> [TaggedPackage] {
        do {
            let refs = try await db.fetchTaggedItems(tagId: tagId)
            // Index the catalogs once for an O(1) lookup per reference.
            let caskByToken = Dictionary(
                casks.map { ($0.token, $0) }, uniquingKeysWith: { a, _ in a }
            )
            let formulaByName = Dictionary(
                formulae.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }
            )
            return refs.compactMap { ref -> TaggedPackage? in
                switch ref.type {
                case .cask:
                    guard let cask = caskByToken[ref.token] else { return nil }
                    return TaggedPackage(
                        token: cask.token,
                        type: .cask,
                        displayName: cask.displayName,
                        desc: cask.desc
                    )
                case .formula:
                    guard let formula = formulaByName[ref.token] else { return nil }
                    return TaggedPackage(
                        token: formula.name,
                        type: .formula,
                        displayName: formula.name,
                        desc: formula.desc
                    )
                }
            }
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    // MARK: - Parked apps
    //
    // "Parking" holds a package's updates: it is excluded from the Updates list
    // and from "Update All"/"Upgrade All" so brew never tries to upgrade it, but
    // it stays tracked so the Parked view can surface a newer Homebrew version
    // and offer Unpark + update. See Models/ParkedApp.swift for the model and
    // the two motivating cases (local-newer-than-brew; deliberately holding an
    // old version). This is ForgedBrew's Park feature.

    // Seeds parkedIDs + parkedRecords from the parkedApps table, then prunes any
    // park that should have ended (a .duration park past its expiry, or a
    // .untilNextVersion park where a newer Homebrew version now exists). Pruned
    // packages drop back into the normal Updates flow automatically. Safe to
    // call on launch and after refreshInstalled (which is when fresh
    // "current version" info is available to evaluate untilNextVersion).
    func loadParked() async {
        do {
            let records = try await db.fetchParkedApps()
            // Evaluate expiry/until-next-version against the freshest installed
            // state, unparking anything that should re-surface.
            var survivors: [ParkedApp] = []
            let now = Date()
            for record in records {
                if shouldAutoUnpark(record, now: now) {
                    // Persisted record has ended; remove it so it re-enters the
                    // Updates list. Best-effort — a failed delete just means it
                    // is re-evaluated next load.
                    try? await db.unpark(token: record.token, type: record.type)
                } else {
                    survivors.append(record)
                }
            }
            parkedRecords = survivors
            parkedIDs = Set(survivors.map { $0.id })
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Decides whether a parked record has reached the end of its park and should
    // be auto-unparked (re-surfaced in Updates):
    //   • .indefinite       → never auto-unparks (only a manual Unpark ends it).
    //   • .duration         → unparks once expiresAt has passed.
    //   • .untilNextVersion → unparks once Homebrew reports a "current" version
    //                          different from the one recorded at park time
    //                          (parkedVersion), i.e. a new release shipped.
    private func shouldAutoUnpark(_ record: ParkedApp, now: Date) -> Bool {
        switch record.parkType {
        case .indefinite:
            return false
        case .duration:
            guard let expiry = record.expiresAt else { return false }
            return now >= expiry
        case .untilNextVersion:
            // Compare the latest Homebrew "current" version (from the freshest
            // installed scan) to what we recorded at park time. If brew now
            // knows a different current version, a newer release shipped →
            // re-surface. If we never recorded a version, or brew has no
            // current-version info, stay parked.
            guard let pkg = installedByToken[record.token],
                  let current = pkg.outdatedInfo?.currentVersion else {
                return false
            }
            guard let parkedVersion = record.parkedVersion else {
                // No baseline to compare against; a fresh outdated signal counts
                // as "a new version is available", so re-surface.
                return true
            }
            return current != parkedVersion
        }
    }

    // True if the given installed package is currently parked.
    func isParked(_ package: InstalledPackage) -> Bool {
        parkedIDs.contains(package.id)
    }

    // True if the (token, type) pair is currently parked.
    func isParked(token: String, type: PackageType) -> Bool {
        parkedIDs.contains("\(type.rawValue):\(token)")
    }

    // Returns the parked record for a package, if any (for the detail/row UI to
    // show the park type).
    func parkedRecord(for package: InstalledPackage) -> ParkedApp? {
        parkedRecords.first { $0.id == package.id }
    }

    // Parks a package: persists the record, updates the in-memory state
    // immediately (so the UI reacts via @Observable), and stamps the current
    // Homebrew version (when known) as the baseline for .untilNextVersion. For
    // .duration parks, computes expiresAt from the chosen ParkDuration.
    func park(
        package: InstalledPackage,
        parkType: ParkType,
        duration: ParkDuration? = nil
    ) async {
        let parkedVersion = package.outdatedInfo?.currentVersion ?? package.installedVersion
        let expiresAt: Date? = (parkType == .duration)
            ? (duration.map { Date().addingTimeInterval($0.seconds) })
            : nil

        // Optimistic in-memory update first so the row leaves Updates instantly.
        let record = ParkedApp(
            token: package.token,
            type: package.type,
            parkType: parkType,
            parkedAt: Date(),
            parkedVersion: parkedVersion,
            expiresAt: expiresAt
        )
        parkedRecords.removeAll { $0.id == record.id }
        parkedRecords.insert(record, at: 0)
        parkedIDs.insert(record.id)

        do {
            try await db.park(
                token: package.token,
                type: package.type,
                parkType: parkType,
                parkedVersion: parkedVersion,
                expiresAt: expiresAt
            )
        } catch {
            // Roll back the optimistic change on persistence failure.
            parkedRecords.removeAll { $0.id == record.id }
            parkedIDs.remove(record.id)
            lastError = error.localizedDescription
        }
    }

    // Unparks a package: removes the record and updates in-memory state so it
    // re-enters the normal Installed/Updates flow.
    func unpark(token: String, type: PackageType) async {
        let id = "\(type.rawValue):\(token)"
        let removed = parkedRecords.first { $0.id == id }
        parkedRecords.removeAll { $0.id == id }
        parkedIDs.remove(id)
        do {
            try await db.unpark(token: token, type: type)
        } catch {
            // Roll back on failure.
            if let removed {
                parkedRecords.insert(removed, at: 0)
                parkedIDs.insert(id)
            }
            lastError = error.localizedDescription
        }
    }

    // Convenience for the Parked view: the parked records paired with their
    // current installed package (when still installed) so the row can show
    // installed vs. latest version and an "update available" hint.
    func parkedPackages() -> [(record: ParkedApp, package: InstalledPackage?)] {
        parkedRecords.map { record in
            (record: record, package: installedByToken[record.token])
        }
    }

    // The set of outdated packages MINUS anything parked — the source of truth
    // for the Updates list and "Update All". Parked packages are still outdated
    // (we keep tracking them) but must not be offered for upgrade here.
    func outdatedExcludingParked() -> [InstalledPackage] {
        installedPackages.filter { $0.isOutdated && !isParked($0) }
    }

    // Checks if cask data is stale (TTL: 6 hours). If stale:
    //   1. Sets isLoadingCasks = true
    //   2. Fetches from BrewAPIService.fetchAllCasks()
    //   3. Saves to DatabaseManager.saveCasks()
    //   4. Calls DatabaseManager.updateRefreshTimestamp(key: "casks")
    // If not stale:
    //   1. Loads from DatabaseManager.fetchAllCasks()
    // Always: updates self.casks, sets isLoadingCasks = false.
    // On error: sets lastError, sets isLoadingCasks = false.
    // `force` (set by a user-initiated Refresh button) bypasses the 6-hour TTL
    // so the catalog is re-fetched immediately rather than reused from the DB.
    // The conditional ETag request still lets Homebrew answer 304 when nothing
    // changed, so a forced refresh is cheap when the catalog is unchanged.
    func refreshCasks(force: Bool = false) async {
        isLoadingCasks = true
        do {
            // A forced refresh skips the TTL check entirely (and avoids the
            // throwing DB call), otherwise consult the 6-hour staleness TTL.
            let isStale: Bool
            if force {
                isStale = true
            } else {
                isStale = try await db.isDataStale(key: "casks", ttlHours: 6.0)
            }
            let fetchedCasks: [CaskMetadata]

            if isStale {
                // Conditional refresh: send the stored ETag so Homebrew can
                // answer 304 Not Modified and let us skip the ~15 MB parse +
                // full DB rewrite when the cask list is unchanged.
                let storedETag = (try? await db.getMetadata(key: "etag_casks")) ?? nil
                let result = try await api.fetchAllCasksConditional(etag: storedETag)
                if let fresh = result.casks {
                    // 200 OK — new data; persist rows + ETag.
                    try await db.saveCasks(fresh)
                    if let newETag = result.etag {
                        try? await db.setMetadata(key: "etag_casks", value: newETag)
                    }
                    fetchedCasks = fresh
                } else {
                    // 304 Not Modified — reuse what's already in the DB.
                    fetchedCasks = try await db.fetchAllCasks()
                }
                try await db.updateRefreshTimestamp(key: "casks")
            } else {
                fetchedCasks = try await db.fetchAllCasks()
            }

            casks = fetchedCasks
            recomputeCategoryCounts()
        } catch {
            lastError = error.localizedDescription
        }
        isLoadingCasks = false
    }

    // Rebuilds categoryCounts from the current `casks`, excluding deprecated
    // entries. Classification runs once per cask here; the result is cached so
    // sidebar rows don't re-classify on every redraw.
    private func recomputeCategoryCounts() {
        var counts: [CaskCategory: Int] = [:]
        var subCounts: [CaskCategory: [String: Int]] = [:]
        for cask in casks where !cask.deprecated {
            // Classify once, reuse for both the category and subcategory tallies.
            let result = CaskClassifier.classify(token: cask.token, desc: cask.desc, homepage: cask.homepage)
            counts[result.category, default: 0] += 1
            subCounts[result.category, default: [:]][result.subcategory, default: 0] += 1
        }
        categoryCounts = counts
        subcategoryCounts = subCounts
    }

    // Mirrors refreshCasks for formulae. TTL: 6 hours, keyed "formulas". The
    // Homebrew formula.json endpoint here has no conditional/ETag variant, so
    // when stale we always fetch + save; when fresh we load from the DB.
    // `force` (user-initiated Refresh) bypasses the 6-hour TTL, same as
    // refreshCasks. The formula endpoint has no conditional/ETag variant, so a
    // forced refresh always re-fetches + re-saves.
    func refreshFormulas(force: Bool = false) async {
        isLoadingFormulae = true
        do {
            // A forced refresh skips the TTL check entirely (and avoids the
            // throwing DB call), otherwise consult the 6-hour staleness TTL.
            let isStale: Bool
            if force {
                isStale = true
            } else {
                isStale = try await db.isDataStale(key: "formulas", ttlHours: 6.0)
            }
            let fetched: [FormulaMetadata]

            if isStale {
                let fresh = try await api.fetchAllFormulas()
                try await db.saveFormulas(fresh)
                try await db.updateRefreshTimestamp(key: "formulas")
                // Re-read through the DB so deprecated/disabled rows are filtered
                // out exactly the same way they are on the fresh-cache path.
                fetched = try await db.fetchAllFormulas()
            } else {
                fetched = try await db.fetchAllFormulas()
            }

            formulae = fetched
            recomputeFormulaCounts()
        } catch {
            lastError = error.localizedDescription
        }
        isLoadingFormulae = false
    }

    // Rebuilds formulaCount + formulaSubcategoryCounts from the current
    // `formulae`. fetchAllFormulas already excludes deprecated/disabled, so every
    // loaded formula is browsable. Classification runs once per formula here and
    // is cached so sidebar rows don't re-classify on every redraw.
    private func recomputeFormulaCounts() {
        var subCounts: [String: Int] = [:]
        var subByToken: [String: String] = [:]
        subByToken.reserveCapacity(formulae.count)
        for formula in formulae {
            let sub = FormulaClassifier.classify(name: formula.name, desc: formula.desc, homepage: formula.homepage)
            subCounts[sub, default: 0] += 1
            subByToken[formula.name] = sub
        }
        formulaSubcategoryCounts = subCounts
        formulaSubcategoryByToken = subByToken
        formulaCount = formulae.count
    }

    // 1. Calls BrewCLIService.listInstalled() → String
    // 2. Decodes JSON as BrewInfoOutput (`brew info --installed --json=v2`)
    // 3. Also calls BrewCLIService.listOutdated() → String, decodes as BrewOutdatedOutput
    // 4. Assembles [InstalledPackage] by merging the two results.
    // 5. Saves to DatabaseManager.saveInstalled()
    // 6. Updates self.installedPackages and rebuilds installedByToken dict
    // Sets isLoadingInstalled around the operation.
    func refreshInstalled() async {
        isLoadingInstalled = true
        do {
            let listString = try await cli.listInstalled()
            let outdatedString = try await cli.listOutdated()

            let decoder = JSONDecoder()
            guard let listData = listString.data(using: .utf8),
                  let outdatedData = outdatedString.data(using: .utf8) else {
                throw BrewCLIError.processError("Failed to encode CLI output as UTF-8 data")
            }

            let listOutput = try decoder.decode(BrewInfoOutput.self, from: listData)
            let outdatedOutput = try decoder.decode(BrewOutdatedOutput.self, from: outdatedData)

            let outdatedCaskTokens = Set(outdatedOutput.casks.map { $0.token })
            let outdatedFormulaNames = Set(outdatedOutput.formulae.map { $0.name })
            let outdatedCaskByToken = Dictionary(
                outdatedOutput.casks.map { ($0.token, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let outdatedFormulaByName = Dictionary(
                outdatedOutput.formulae.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            // Resolve the brew prefix once so we can build Cellar keg paths for
            // formula size probes (Apple Silicon vs Intel layout).
            let brewPrefix = FileManager.default.fileExists(atPath: "/opt/homebrew")
                ? "/opt/homebrew" : "/usr/local"

            // Per-token: the absolute path we'll measure for size, and the
            // install/update date pulled straight from the brew JSON.
            var sizePathByToken: [String: String] = [:]
            var dateByToken: [String: Date] = [:]

            var packages: [InstalledPackage] = []

            for caskInfo in listOutput.casks {
                let isOutdated = outdatedCaskTokens.contains(caskInfo.token)
                var info: OutdatedInfo? = nil
                if let o = outdatedCaskByToken[caskInfo.token] {
                    info = OutdatedInfo(
                        currentVersion: o.currentVersion,
                        installedVersion: o.installedVersions.first ?? (caskInfo.version ?? "?"),
                        pinned: false
                    )
                }
                // Date: cask `installed_time` (epoch seconds).
                if let t = caskInfo.installedTime {
                    dateByToken[caskInfo.token] = Date(timeIntervalSince1970: t)
                }
                // Size path: the installed app bundle (the Caskroom dir is only
                // metadata). Falls back to the Caskroom dir when there's no app
                // artifact (pkg/binary casks) so we still report SOMETHING.
                if let appPath = caskInfo.appPath {
                    sizePathByToken[caskInfo.token] = appPath
                } else {
                    sizePathByToken[caskInfo.token] = "\(brewPrefix)/Caskroom/\(caskInfo.token)"
                }
                packages.append(InstalledPackage(
                    token: caskInfo.token,
                    type: .cask,
                    installedVersion: caskInfo.version,
                    isOutdated: isOutdated,
                    outdatedInfo: info
                ))
            }

            for formulaInfo in listOutput.formulae {
                let isOutdated = outdatedFormulaNames.contains(formulaInfo.name)
                let firstInstalled = formulaInfo.installed.first
                let localVersion = firstInstalled?.version
                var info: OutdatedInfo? = nil
                if let o = outdatedFormulaByName[formulaInfo.name] {
                    info = OutdatedInfo(
                        currentVersion: o.currentVersion,
                        installedVersion: o.installedVersions.first ?? (localVersion ?? "?"),
                        pinned: o.pinned
                    )
                }
                // Date: the keg's INSTALL_RECEIPT.json `time` (epoch seconds).
                if let t = firstInstalled?.time {
                    dateByToken[formulaInfo.name] = Date(timeIntervalSince1970: t)
                }
                // Size path: the formula's Cellar directory.
                sizePathByToken[formulaInfo.name] = "\(brewPrefix)/Cellar/\(formulaInfo.name)"
                packages.append(InstalledPackage(
                    token: formulaInfo.name,
                    type: .formula,
                    installedVersion: localVersion,
                    isOutdated: isOutdated,
                    outdatedInfo: info,
                    installedOnRequest: firstInstalled?.installedOnRequest ?? true,
                    dependencies: formulaInfo.dependencies
                ))
            }

            // Measure sizes for all resolved paths in a single `du` pass, then
            // fold the results (plus the dates parsed above) back onto each
            // package. Sizing is best-effort: a path we can't read just leaves
            // sizeBytes nil and the UI omits the size for that row.
            let pathToBytes = await cli.sizesForPaths(Array(sizePathByToken.values))
            packages = packages.map { pkg in
                let bytes = sizePathByToken[pkg.token].flatMap { pathToBytes[$0] }
                let date = dateByToken[pkg.token]
                return InstalledPackage(
                    token: pkg.token,
                    type: pkg.type,
                    installedVersion: pkg.installedVersion,
                    isOutdated: pkg.isOutdated,
                    outdatedInfo: pkg.outdatedInfo,
                    sizeBytes: bytes,
                    installedDate: date,
                    installedOnRequest: pkg.installedOnRequest,
                    dependencies: pkg.dependencies
                )
            }

            try await db.saveInstalled(packages)
            installedPackages = packages
            installedByToken = Dictionary(uniqueKeysWithValues: packages.map { ($0.token, $0) })

            // Index installed packages into Spotlight (best-effort, enriched with
            // catalog metadata for display names + descriptions).
            SpotlightIndexer.index(packages: packages, casks: casks)

            // The set of installed apps may have changed; drop cached
            // app-icon lookups so newly installed apps show real icons.
            AppIconService.shared.invalidate()

            // Re-evaluate parks against the freshest version info: this is when
            // a .untilNextVersion park can detect a newly-shipped release, and a
            // .duration park its expiry, and auto-unpark so the package
            // re-enters the Updates list. Also drops parks for packages that are
            // no longer installed (uninstalled out from under us).
            await loadParked()
            await pruneParksForUninstalled()
        } catch {
            lastError = error.localizedDescription
        }
        isLoadingInstalled = false
        // Mark that the Homebrew inventory has loaded at least once so
        // navigation into the Installed / Updates panels no longer forces a
        // brew re-read on every click.
        hasLoadedInstalledOnce = true
    }

    // Removes park records whose package is no longer installed (e.g. the user
    // uninstalled it elsewhere). Keeps the Parked view from listing ghosts.
    private func pruneParksForUninstalled() async {
        let installedIDs = Set(installedPackages.map { $0.id })
        let ghosts = parkedRecords.filter { !installedIDs.contains($0.id) }
        guard !ghosts.isEmpty else { return }
        for ghost in ghosts {
            try? await db.unpark(token: ghost.token, type: ghost.type)
        }
        parkedRecords.removeAll { ghost in ghosts.contains { $0.id == ghost.id } }
        parkedIDs = Set(parkedRecords.map { $0.id })
    }

    // Fetches 30d cask analytics from BrewAPIService.
    // Builds [String: Int] dict from formulae entries (cask token → installCount).
    // Calls DatabaseManager.updateInstallCounts(counts, period: "30d").
    // Silently ignores errors (analytics are non-critical).
    func refreshAnalytics() async {
        do {
            let response = try await api.fetchCaskAnalytics(period: "30d")
            var counts: [String: Int] = [:]
            for (_, entries) in response.formulae {
                for entry in entries {
                    counts[entry.cask] = entry.installCount
                }
            }
            try await db.updateInstallCounts(counts, period: "30d")
        } catch {
            // Silently ignore errors — analytics are non-critical.
        }

        // 90d cask analytics power the "3-Month Trend" sort. Same endpoint
        // shape as 30d (formulae object: cask token → count). Independent
        // do/catch so a 90d failure never suppresses the 30d counts above.
        do {
            let response90 = try await api.fetchCaskAnalytics(period: "90d")
            var counts90: [String: Int] = [:]
            for (_, entries) in response90.formulae {
                for entry in entries {
                    counts90[entry.cask] = entry.installCount
                }
            }
            try await db.updateInstallCounts(counts90, period: "90d")
        } catch {
            // Silently ignore errors — analytics are non-critical.
        }

        // 365d cask analytics power the "Top Past Year" sort. Same endpoint
        // shape as 30d/90d (formulae object: cask token → count). Independent
        // do/catch so a 365d failure never suppresses the counts above.
        do {
            let response365 = try await api.fetchCaskAnalytics(period: "365d")
            var counts365: [String: Int] = [:]
            for (_, entries) in response365.formulae {
                for entry in entries {
                    counts365[entry.cask] = entry.installCount
                }
            }
            try await db.updateInstallCounts(counts365, period: "365d")
        } catch {
            // Silently ignore errors — analytics are non-critical.
        }

        // Formula analytics are independent of cask analytics — keep them in a
        // separate do/catch so a failure in one doesn't suppress the other.
        await refreshFormulaAnalytics()
    }

    // Fetches 30d formula analytics, maps install counts onto the formulas table
    // (keyed by name), then re-loads the in-memory `formulae` so the Home
    // "Most Downloaded" formulae list ranks by real counts. This runs after
    // refreshFormulas (which sets counts to 0 from the catalog cache), so the
    // re-load here is what makes the ranking reflect actual installs.
    private func refreshFormulaAnalytics() async {
        do {
            let response = try await api.fetchFormulaAnalytics(period: "30d")
            var counts: [String: Int] = [:]
            for item in response.items {
                // Analytics names can carry tap prefixes (e.g.
                // "hashicorp/tap/terraform"); the catalog stores the bare leaf
                // name. Map onto the leaf, but never let a tap-prefixed entry
                // overwrite a core (unprefixed) entry for the same leaf.
                let isCore = !item.formula.contains("/")
                let key = isCore ? item.formula : String(item.formula.split(separator: "/").last ?? "")
                if key.isEmpty { continue }
                if isCore {
                    counts[key] = item.installCount
                } else if counts[key] == nil {
                    counts[key] = item.installCount
                }
            }
            try await db.updateFormulaInstallCounts(counts)

            // Re-load formulae from the DB so the updated counts propagate to
            // the Home ranked list. recomputeFormulaCounts keeps sidebar
            // tallies consistent (counts don't change them, but it's cheap).
            formulae = try await db.fetchAllFormulas()
            recomputeFormulaCounts()
        } catch {
            // Silently ignore errors — analytics are non-critical.
        }
    }

    // Delegates to BrewCLIService.install(cask:).
    // Re-yields the CLI stream into a fresh stream returned to the caller,
    // so the UI can display live output while we also observe completion.
    // After the stream ends, logs to DatabaseManager.logInstallEvent and refreshes installed state.
    func install(cask: String) -> AsyncStream<String> {
        relay(token: cask, type: .cask, action: "install") { [cli] in
            await cli.install(cask: cask)
        }
    }

    // Formula install / uninstall / upgrade, mirroring the cask paths but
    // routing through the formula CLI entry points and logging type .formula.
    func installFormula(_ name: String) -> AsyncStream<String> {
        relay(token: name, type: .formula, action: "install") { [cli] in
            await cli.installFormula(name)
        }
    }

    func uninstallFormula(_ name: String) -> AsyncStream<String> {
        relay(token: name, type: .formula, action: "uninstall") { [cli] in
            await cli.uninstallFormula(name)
        }
    }

    func upgradeFormula(_ name: String) -> AsyncStream<String> {
        relay(token: name, type: .formula, action: "upgrade") { [cli] in
            await cli.upgradeFormula(name)
        }
    }

    // Same pattern as install but calls BrewCLIService.uninstall(cask:)
    func uninstall(cask: String) -> AsyncStream<String> {
        relay(token: cask, type: .cask, action: "uninstall") { [cli] in
            await cli.uninstall(cask: cask)
        }
    }

    // Delegates to BrewCLIService.upgrade(cask:), logs event, refreshes installed.
    func upgrade(cask: String) -> AsyncStream<String> {
        relay(token: cask, type: .cask, action: "upgrade") { [cli] in
            await cli.upgrade(cask: cask)
        }
    }

    // MARK: - Shared install manager API
    //
    // These are the entry points views should call. Each spins up a long-lived
    // Task on the singleton (stored in installTasks) that consumes the brew
    // stream itself, so the operation continues even if the originating view is
    // dismissed. Progress is published to installProgress[token].

    // Starts (or upgrades) an install. After a successful install it runs
    // `brew cleanup` — the safe-install disk tidy (old versions, stale locks,
    // outdated downloads) per our design outline. Casks are the
    // default; pass `isFormula: true` to route through the formula CLI instead.
    // No-op if an operation is already in flight for this token.
    func startInstall(
        token: String,
        isUpgrade: Bool = false,
        isFormula: Bool = false,
        sudoPassword: String? = nil,
        // When false, the per-app `brew cleanup` at the end is skipped. Batch
        // updates (Update Selected / Update All) set this false and run ONE
        // shared cleanup after the whole batch instead. Reason: when several
        // upgrades run concurrently, each ending with its own `brew cleanup`,
        // the cleanup subprocesses pile up behind Homebrews global lock and
        // the UI gets stuck showing \"Cleaning up…\" on rows whose brew work has
        // actually finished. One cleanup at the end avoids that entirely (and
        // is faster). Single-app updates keep runCleanup = true.
        runCleanup: Bool = true
    ) {
        guard installTasks[token] == nil else { return }

        // The view layer gates on ensureSessionSudoPassword() before calling us,
        // so by the time we're here the session password (if any) is already
        // captured. We simply use whatever we were handed, falling back to the
        // cached session password. The SUDO_ASKPASS helper means a password is
        // harmless for apps that don't need root (sudo is just never invoked),
        // so we no longer inspect per-cask sudo needs here.
        let password = sudoPassword ?? sessionSudoPassword
        // "" is a legacy sentinel meaning "no password"; normalize to nil so we
        // run the plain (non-askpass) path.
        let effectivePassword: String? = (password == "") ? nil : password

        installProgress[token] = InstallProgress(phase: .preparing, log: [])
        let task = Task { [weak self] in
            guard let self else { return }

            // 1. Install / upgrade (cask or formula entry points).
            let installStream: AsyncStream<String>
            if isFormula {
                installStream = isUpgrade
                    ? await self.cli.upgradeFormula(token, sudoPassword: effectivePassword)
                    : await self.cli.installFormula(token, sudoPassword: effectivePassword)
            } else {
                installStream = isUpgrade
                    ? await self.cli.upgrade(cask: token, sudoPassword: effectivePassword)
                    : await self.cli.install(cask: token, sudoPassword: effectivePassword)
            }
            var sawPasswordPrompt = false
            for await line in installStream {
                self.appendLog(token: token, line: line)
                // Advance the user-facing phase as brew emits `==> <Verb>`
                // markers (Downloading…, Installing…, Removing old version…).
                if let phase = InstallProgress.phase(forLine: line) {
                    self.setPhase(token: token, phase: phase)
                }
                // Runtime sudo fallback: brew is asking for a password and our
                // askpass either wasn't set or was wrong. Note it so we can
                // re-prompt after the stream ends.
                if BrewCLIService.lineRequestsPassword(line) {
                    sawPasswordPrompt = true
                }
            }

            // Wrong / rejected password recovery. With SUDO_ASKPASS, sudo never
            // prints a visible `Password:` prompt (so sawPasswordPrompt stays
            // false on the common path) — a bad password instead shows up as a
            // rejection message (`N incorrect password attempts`, `Sorry, try
            // again`, etc.). Detect that directly, clear the bad cached session
            // password, and re-prompt + retry. Without this, a single mistyped
            // password both fails the op AND poisons the cached password for
            // every later action this session. `sawPasswordPrompt` is kept as a
            // secondary trigger for the rare config where sudo DOES echo a
            // prompt without an explicit rejection line.
            if self.logIndicatesWrongPassword(token: token)
                || (sawPasswordPrompt && !self.logIndicatesSuccessfulPasswordUse(token: token)) {
                self.handlePasswordPromptFailure(
                    token: token, isFormula: isFormula, isUpgrade: isUpgrade,
                    zap: false, kind: .install
                )
                return
            }

            // Detect failure from the tail of the log (brew prints "Error:" /
            // "failed" on the last lines when something goes wrong).
            if self.logIndicatesFailure(token: token) {
                // Automatic recovery for the shared-directory cask-upgrade abort
                // (e.g. Microsoft Excel/Word/etc.): brew's upgrade removes the
                // old version first, and its rmdir.sh exits non-zero on a
                // non-empty shared dir like `/Library/Application
                // Support/Microsoft`, aborting BEFORE the new version is poured.
                // A forced reinstall pours the new version without that failing
                // pre-removal step. We only retry once, only for cask upgrades,
                // and only when the failure signature is exactly this one (no
                // other hard error present), so unrelated failures still surface
                // normally. Our forced-reinstall workaround.
                if isUpgrade && !isFormula
                    && self.logIndicatesSharedDirCleanupFailure(token: token) {
                    self.appendLog(
                        token: token,
                        line: "==> Upgrade hit a shared-directory cleanup error; "
                            + "retrying with a forced reinstall…"
                    )
                    self.setPhase(token: token, phase: .installing)
                    for await line in await self.cli.reinstall(
                        cask: token, sudoPassword: effectivePassword
                    ) {
                        self.appendLog(token: token, line: line)
                        if let phase = InstallProgress.phase(forLine: line) {
                            self.setPhase(token: token, phase: phase)
                        }
                    }
                    // If the reinstall hit a password rejection, recover the
                    // same way the first attempt does: clear the poisoned
                    // session password and re-prompt + retry, rather than
                    // surfacing a hard failure. (We only reach here because the
                    // FIRST attempt passed the wrong-password gate above, so any
                    // rejection in the log now came from this reinstall step.)
                    if self.logIndicatesWrongPassword(token: token) {
                        self.handlePasswordPromptFailure(
                            token: token, isFormula: isFormula, isUpgrade: isUpgrade,
                            zap: false, kind: .install
                        )
                        return
                    }
                    // If the reinstall ALSO failed for some other reason,
                    // surface that error now (no further retry).
                    if self.logIndicatesFailure(token: token) {
                        self.finish(token: token, failure: self.failureMessage(token: token))
                        return
                    }
                    // Reinstall succeeded — fall through to cleanup + refresh.
                } else {
                    self.finish(token: token, failure: self.failureMessage(token: token))
                    return
                }
            }

            // 2. Log the event + refresh shared installed state app-wide so every
            //    view (Home cards, sidebar, Installed list) reflects it, then mark
            //    the row Done IMMEDIATELY. The package is fully installed at this
            //    point — the deep clean below is a disk-tidy that does not affect
            //    whether the app works, so the user should not be made to wait on
            //    a "Cleaning up…" spinner for it.
            await self.logAndRefresh(token: token, action: isUpgrade ? "upgrade" : "install")
            self.finish(token: token, failure: nil)

            // 3. Post-install deep clean (per our design outline). Best-effort and
            //    fully DETACHED from the row's completion state: the row already
            //    reads "Done", so this heavy `brew cleanup --prune=all -s -v`
            //    (which scans the whole cache and can take a while) runs quietly
            //    in the background instead of pinning the row on "Cleaning up…".
            //    Its output is still appended to the log for troubleshooting. A
            //    cleanup hiccup never affects the install result.
            //
            //    Skipped when runCleanup == false (batch updates): the caller
            //    runs a single shared `brew cleanup` after the whole batch, which
            //    avoids the concurrent-cleanup pile-up.
            if runCleanup {
                Task { [weak self] in
                    guard let self else { return }
                    self.appendLog(token: token, line: "==> Running brew cleanup (background)…")
                    for await line in await self.cli.cleanup() {
                        self.appendLog(token: token, line: line)
                    }
                }
            }
        }
        installTasks[token] = task
    }

    // Batch upgrade for multi-select "Update Selected". Starts an upgrade for
    // every package with per-app cleanup DISABLED, waits for them all to
    // finish, then runs ONE shared `brew cleanup`. This is what fixes the
    // "stuck on Cleaning up…" hang: previously each concurrent upgrade ran its
    // own cleanup, and those cleanup subprocesses queued behind Homebrews
    // global lock so rows whose brew work had finished kept showing
    // "Cleaning up…" indefinitely. One cleanup at the end is correct and
    // faster.
    //
    // Each package still shows its own live phase + progress bar during its
    // upgrade. The shared cleanup briefly shows a "Cleaning up…" phase on the
    // packages just upgraded so the user sees the tidy step happen, then they
    // all settle to Done together.
    func startBatchUpgrade(packages: [InstalledPackage], sudoPassword: String?) {
        guard !packages.isEmpty else { return }

        // Register every token as batch-managed BEFORE starting, so when each
        // per-app upgrade calls finish() it pins the row on "Cleaning up…" and
        // skips its own auto-clear (the batch clears them after the shared
        // cleanup). Done synchronously here (were on the main actor) so its
        // set before any upgrade can finish.
        let tokens = packages.map(\.token)
        batchManagedClearTokens.formUnion(tokens)

        Task { [weak self] in
            guard let self else { return }

            // 1. Kick off every per-app upgrade WITHOUT its own cleanup.
            for pkg in packages {
                self.startInstall(
                    token: pkg.token,
                    isUpgrade: true,
                    isFormula: pkg.type == .formula,
                    sudoPassword: sudoPassword,
                    runCleanup: false
                )
            }

            // 2. Wait for each upgrade task to complete. Awaiting a Task value
            //    blocks until it finishes (the gate inside BrewCLIService still
            //    serializes the actual brew subprocesses one at a time). As each
            //    finishes, finish() has already pinned its row on "Cleaning up…".
            for pkg in packages {
                await self.installTasks[pkg.token]?.value
            }

            // 3. One shared `brew cleanup` for the whole batch. The successfully
            //    upgraded rows are already showing "Cleaning up…" (pinned by
            //    finish()); they STAY pinned through this single cleanup pass.
            //    Rows that failed are no longer batch-managed and show their
            //    error. We only finalize the ones still pinned on cleaningUp.
            let pinned = packages.filter { self.installProgress[$0.token]?.phase == .cleaningUp }
            for await line in await self.cli.cleanup() {
                for pkg in pinned {
                    self.installProgress[pkg.token]?.log.append(line)
                }
            }

            // 4. Shared cleanup done: mark each pinned row Done, drop its
            //    batch-managed flag, and schedule the normal 4-second HUD fade.
            for pkg in pinned {
                self.batchManagedClearTokens.remove(pkg.token)
                self.installProgress[pkg.token]?.phase = .finished
                self.scheduleProgressClear(token: pkg.token)
            }
            // Safety: clear flags for any tokens that didnt end up pinned
            // (e.g. failed) so the set never leaks entries.
            self.batchManagedClearTokens.subtract(tokens)
        }
    }

    // Re-arms the 4-second auto-clear of a tokens progress HUD (used after the
    // shared batch cleanup re-touches a row that already finished, so its HUD
    // still fades on the same timing as a normal single-app finish).
    private func scheduleProgressClear(token: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            if self.installTasks[token] == nil {
                self.installProgress[token] = nil
            }
        }
    }

    // Starts a package uninstall. For casks with `zap == true` it uses `brew
    // uninstall --cask --zap` to also remove the app's leftover support/config
    // files (the per-app "clean uninstall" the Installed list offers); a plain
    // cask uninstall otherwise. When `isFormula` is true it routes through the
    // formula CLI instead (zap doesn't apply to formulae). No-op if an
    // operation is already in flight for this token.
    func startUninstall(
        token: String,
        zap: Bool = false,
        isFormula: Bool = false,
        sudoPassword: String? = nil
    ) {
        guard installTasks[token] == nil else { return }

        // The view layer gates on ensureSessionSudoPassword() before calling us
        // (same as startInstall), so use whatever password we were handed,
        // falling back to the cached session password.
        let password = sudoPassword ?? sessionSudoPassword
        let effectivePassword: String? = (password == "") ? nil : password

        installProgress[token] = InstallProgress(phase: .uninstalling, log: [], isUninstall: true)
        let task = Task { [weak self] in
            guard let self else { return }

            let stream: AsyncStream<String>
            if isFormula {
                stream = await self.cli.uninstallFormula(token, sudoPassword: effectivePassword)
            } else if zap {
                stream = await self.cli.uninstallZap(cask: token, sudoPassword: effectivePassword)
            } else {
                stream = await self.cli.uninstall(cask: token, sudoPassword: effectivePassword)
            }
            var sawPasswordPrompt = false
            for await line in stream {
                self.appendLog(token: token, line: line)
                // Uninstall stays in the .uninstalling phase, but if brew emits
                // a removal marker keep the phase consistent (defensive).
                if let phase = InstallProgress.phase(forLine: line),
                   phase == .removingOld {
                    self.setPhase(token: token, phase: .uninstalling)
                }
                if BrewCLIService.lineRequestsPassword(line) {
                    sawPasswordPrompt = true
                }
            }

            // Same wrong/rejected-password recovery as the install path: detect
            // the rejection directly (askpass means no visible prompt), clear the
            // bad cached password, and re-prompt + retry instead of failing.
            if self.logIndicatesWrongPassword(token: token)
                || (sawPasswordPrompt && !self.logIndicatesSuccessfulPasswordUse(token: token)) {
                self.handlePasswordPromptFailure(
                    token: token, isFormula: isFormula, isUpgrade: false,
                    zap: zap, kind: .uninstall
                )
                return
            }

            if self.logIndicatesFailure(token: token) {
                self.finish(token: token, failure: self.failureMessage(token: token))
                return
            }

            await self.logAndRefresh(token: token, action: "uninstall")
            self.finish(token: token, failure: nil)
        }
        installTasks[token] = task
    }

    // MARK: - Sudo request / resume

    // Raises a password request for a queued operation. The closure captured in
    // `queuedSudoOperations` re-invokes the right start method once the password
    // arrives. Called on the MainActor (from inside a Task that already hopped).
    private func enqueueSudoOperation(
        token: String,
        isFormula: Bool,
        isUpgrade: Bool,
        zap: Bool,
        kind: SudoRequest.Kind
    ) {
        let request = SudoRequest(
            token: token,
            displayName: SudoRequest.prettyName(for: token),
            isFormula: isFormula,
            isUpgrade: isUpgrade,
            zap: zap,
            kind: kind
        )
        queuedSudoOperations[request.id] = { [weak self] in
            guard let self else { return }
            // Re-enter the right start method WITH the now-known session password.
            switch kind {
            case .install:
                self.startInstall(
                    token: token, isUpgrade: isUpgrade, isFormula: isFormula,
                    sudoPassword: self.sessionSudoPassword
                )
            case .uninstall:
                self.startUninstall(
                    token: token, zap: zap, isFormula: isFormula,
                    sudoPassword: self.sessionSudoPassword
                )
            }
        }
        pendingSudoRequest = request
    }

    // Called by the password sheet. When `password` is non-nil the user
    // confirmed: store it for the session (memory only). When nil the user
    // cancelled. Either way we invoke the queued resume closure, which decides
    // what to do (a single-package op retries iff a password now exists; the
    // upgrade-all continuation resumes with the current session password, which
    // is nil on cancel). On cancel we also clear the placeholder HUD entry.
    func provideSudoPassword(_ password: String?, for request: SudoRequest) {
        pendingSudoRequest = nil
        let resume = queuedSudoOperations.removeValue(forKey: request.id)
        if let password, !password.isEmpty {
            sessionSudoPassword = password
            resume?()
        } else {
            // Cancelled. Tear down the placeholder progress entry, then still
            // invoke the resume closure so any awaiting continuation (e.g.
            // Update-All) is released rather than hanging forever. Single-package
            // closures call startInstall/startUninstall which will simply re-
            // prompt; to avoid an immediate re-prompt loop on an explicit cancel,
            // those closures are NOT invoked here — only continuation-style ones.
            installProgress[request.token] = nil
            // The continuation closures stored by prepareSudoForUpgradeAll resume
            // with the (now nil) session password; invoking them is safe and
            // necessary. Single-op closures re-enter start*, which would re-
            // prompt; we suppress that by only resuming continuation-backed
            // requests (Update-All).
            if request.isContinuation {
                resume?()
            }
        }
    }

    // Runtime fallback when brew asked for a password mid-run that our askpass
    // couldn't satisfy (e.g. a wrong session password). Clear the bad password
    // and re-raise a request so the user can re-enter it; the queued op retries.
    private func handlePasswordPromptFailure(
        token: String,
        isFormula: Bool,
        isUpgrade: Bool,
        zap: Bool,
        kind: SudoRequest.Kind
    ) {
        sessionSudoPassword = nil  // it was wrong (or absent); force a re-entry
        installTasks[token] = nil
        installProgress[token] = InstallProgress(phase: .needsPassword, log: [],
                                                 isUninstall: kind == .uninstall)
        enqueueSudoOperation(
            token: token, isFormula: isFormula, isUpgrade: isUpgrade,
            zap: zap, kind: kind
        )
    }

    // Heuristic: did the run actually use the password successfully? If brew
    // reached an install/pour/success marker after asking, the password worked.
    // Used to avoid re-prompting on a benign `Password:` echo.
    private func logIndicatesSuccessfulPasswordUse(token: String) -> Bool {
        return !logIndicatesWrongPassword(token: token)
    }

    // True when the run's output shows the admin password was REJECTED by sudo
    // (or brew). This is the signal to clear the cached session password and
    // re-prompt + retry, rather than failing the whole operation.
    //
    // With our SUDO_ASKPASS helper, sudo never prints a `Password:` prompt to
    // stdout (it reads the password silently from the askpass program), so a
    // wrong password does NOT surface as a password prompt — it surfaces only as
    // one of these rejection messages. sudo emits `N incorrect password
    // attempt(s)` after exhausting its retries (the askpass returns the same bad
    // password each time); other configs say `Sorry, try again.` or
    // `authentication failure`. We match all of them so a mistyped password is
    // recoverable instead of cascading into a broken session.
    private func logIndicatesWrongPassword(token: String) -> Bool {
        let log = installProgress[token]?.log ?? []
        for raw in log {
            let line = raw.lowercased()
            if line.contains("incorrect password attempt")   // sudo: N incorrect password attempt(s)
                || line.contains("sorry, try again")          // classic sudo retry message
                || line.contains("incorrect password")        // brew/other wording
                || line.contains("authentication failure")    // PAM
                || line.contains("a terminal is required")    // askpass missing/failed
                || line.contains("sudo: a password is required") {
                return true
            }
        }
        return false
    }

    // Wipes the in-memory session password. Called on app termination so a fresh
    // launch always re-prompts for privileged updates.
    func wipeSessionSudoPassword() {
        sessionSudoPassword = nil
    }

    // The password to use for a sudo run, or nil. Exposed (read-only) so the
    // Update-All flow can pass it straight to `upgradeAll(sudoPassword:)`.
    var currentSessionSudoPassword: String? {
        sessionSudoPassword
    }

    // The single session-password gate. Every update/upgrade/uninstall entry
    // point calls this FIRST. If we already captured the admin password this
    // session, it returns immediately (silent reuse). Otherwise it raises ONE
    // password prompt — regardless of whether the specific app actually needs
    // root — and awaits the user's input via a continuation.
    //
    // Per the user's chosen model: the first privileged action of a session
    // always prompts (even for apps that don't strictly need sudo), the password
    // is cached in memory for the rest of the session, and wiped on quit. A
    // cancel returns nil, and callers treat nil as "abort this action".
    //
    // `verb`/`subject` only customize the sheet copy (e.g. "update your apps").
    func ensureSessionSudoPassword(
        verb: String = "update",
        subject: String = "your apps"
    ) async -> String? {
        // Already have one for the session — reuse it silently.
        if let existing = sessionSudoPassword { return existing }

        // Raise a single prompt and await the user's input via a continuation.
        let request = SudoRequest(
            token: subject,
            displayName: subject,
            isFormula: false,
            isUpgrade: (verb == "update"),
            zap: false,
            kind: .install,
            isContinuation: true
        )
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // provideSudoPassword always invokes a continuation-backed closure
            // (both on success and cancel), so resuming with the current session
            // password yields the entered value on success or nil on cancel.
            queuedSudoOperations[request.id] = { [weak self] in
                continuation.resume(returning: self?.sessionSudoPassword)
            }
            pendingSudoRequest = request
        }
    }

    // Back-compat shim: older call sites passed a list of cask tokens. We no
    // longer inspect per-cask sudo needs — the session gate prompts once for
    // everything — so this just forwards to ensureSessionSudoPassword.
    func prepareSudoForUpgradeAll(outdatedCaskTokens: [String]) async -> String? {
        await ensureSessionSudoPassword(verb: "update", subject: "your apps")
    }

    // MARK: - Shared install manager internals

    // MARK: - App updates via topgrade

    // True while a topgrade app update is running for this bundle id.
    func isAppUpdating(bundleID: String) -> Bool {
        appUpdateTasks[bundleID] != nil
    }

    // True while the aggregate "Update All Apps" run is in flight.
    var isUpdatingAllApps: Bool {
        appUpdateTasks[AppDataService.allAppsUpdateKey] != nil
    }

    // Update ONE non-Homebrew app in place via topgrade, scoped to just that
    // app's update mechanism (its source's topgrade step). The view gates on
    // ensureSessionSudoPassword() first, so by the time we're here the session
    // password (if the user provided one) is already captured. mas apps need no
    // root; casks/sparkle/office authenticate non-interactively via SUDO_ASKPASS.
    func startAppUpdate(_ update: AppUpdate, sudoPassword: String? = nil) {
        let key = update.bundleID
        guard appUpdateTasks[key] == nil else { return }
        guard let step = TopgradeService.step(for: update.source) else {
            // GitHub-release apps have no topgrade step — caller should have used
            // the Website button. Surface a clear, non-fatal message.
            appUpdateProgress[key] = InstallProgress(
                phase: .failed("ForgedBrew can't update this app in place — use the Website button."),
                log: []
            )
            scheduleAppProgressClear(key: key)
            return
        }

        let password = sudoPassword ?? sessionSudoPassword
        let effectivePassword: String? = (password == "") ? nil : password

        appUpdateProgress[key] = InstallProgress(phase: .preparing, log: [], verb: "Updating")
        let task = Task { [weak self] in
            guard let self else { return }
            let stream = TopgradeService.shared.run(steps: [step], sudoPassword: effectivePassword)
            for await line in stream {
                self.appUpdateProgress[key]?.log.append(line)
                if let phase = InstallProgress.phase(forLine: line) {
                    self.appUpdateProgress[key]?.phase = phase
                }
            }
            self.finishAppUpdate(key: key)
            // A successful in-place update changes installed versions; rescan the
            // non-Homebrew inventory so the row drops out of the list.
            await self.refreshAppUpdates()
            // Now that the inventory is fresh, reconcile the real outcome. topgrade
            // exits 0 even when an app silently fails to update (e.g. cotypist,
            // which manages its own updates), so the log-only check in
            // finishAppUpdate can mark it "Done" when nothing actually changed.
            // If the app STILL has an available update after the rescan, the
            // update didn't take — surface the failure instead of a false "Done".
            self.reconcileSingleAppUpdateOutcome(bundleID: key, name: update.appName)
        }
        appUpdateTasks[key] = task
    }

    // After a single-app in-place run + rescan, verify the update actually took.
    // topgrade reports success (exit 0, no error lines) even for apps it can't
    // truly update in place, so finishAppUpdate may have shown "Done". If the app
    // still appears in the updates list, the version didn't change: flip the HUD
    // to a failure with our standard message and record it on the persistent
    // "some apps can't be updated here" banner. If it dropped out, it succeeded
    // and any stale error flag is cleared. The aggregate key is never reconciled
    // here (it has its own reconcileAllAppUpdateOutcome path).
    private func reconcileSingleAppUpdateOutcome(bundleID: String, name: String) {
        guard bundleID != AppDataService.allAppsUpdateKey else { return }
        let stillUpdatable = Set(AppUpdateService.shared.updates.map { $0.bundleID })
        if stillUpdatable.contains(bundleID) {
            appUpdateProgress[bundleID]?.phase =
                .failed("Couldn't update this app in place. Open the app or website to update manually.")
            AppUpdateService.shared.recordUpdateError(bundleID: bundleID, appName: name)
            // The phase was just changed after finishAppUpdate already scheduled a
            // clear; re-schedule so the corrected failure state still auto-clears.
            scheduleAppProgressClear(key: bundleID)
        } else {
            AppUpdateService.shared.clearUpdateError(bundleID: bundleID)
        }
    }

    // Mac App Store update for a SINGLE app, driven directly by `mas upgrade
    // <storeID>` rather than topgrade's broad "mas" step. This lets us give the
    // user a precise outcome per app: a live HUD on success, and on any failure
    // a clear "needs the App Store" message (the row's Open App Store button
    // deep-links straight to the app). We never surface a raw/opaque failure.
    func startMASUpdate(_ update: AppUpdate) {
        let key = update.bundleID
        guard appUpdateTasks[key] == nil else { return }

        appUpdateProgress[key] = InstallProgress(phase: .installing, log: [], verb: "Updating")
        let storeID = update.storeID
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await AppUpdateService.upgradeViaMAS(storeID: storeID)
            switch result {
            case .succeeded:
                self.appUpdateProgress[key]?.phase = .finished
            case .failed, .unavailable:
                // Deliberately app-store-specific and actionable — the row shows
                // an "Open App Store" button alongside this message.
                self.appUpdateProgress[key]?.phase =
                    .failed("This app needs to be updated in the App Store")
            }
            self.finishMASUpdate(key: key)
            // A successful upgrade changes installed versions; rescan so the row
            // drops out of the list.
            if case .succeeded = result {
                await self.refreshAppUpdates()
            }
        }
        appUpdateTasks[key] = task
    }

    // Settle a MAS-update HUD WITHOUT overriding the phase we set explicitly
    // above (finishAppUpdate re-derives failed/finished from the topgrade log,
    // which a mas-driven run doesn't produce). Just drop the task and schedule
    // the auto-clear.
    private func finishMASUpdate(key: String) {
        appUpdateTasks[key] = nil
        scheduleAppProgressClear(key: key)
    }

    // Update ALL non-Homebrew apps in place. Collapses the distinct sources of

    // the supplied updates into the minimal set of topgrade steps and runs them
    // in one pass (also runs microsoft_office, which has its own updater). The
    // aggregate run is tracked under allAppsUpdateKey so the header button can
    // show a single live status.
    func startAllAppUpdates(_ updates: [AppUpdate], sudoPassword: String? = nil) {
        let key = AppDataService.allAppsUpdateKey
        guard appUpdateTasks[key] == nil else { return }

        // Derive steps from the visible updates, always including office (its
        // check is cheap and self-contained). De-dupe while preserving order.
        var steps: [String] = []
        for u in updates {
            if let s = TopgradeService.step(for: u.source), !steps.contains(s) {
                steps.append(s)
            }
        }
        if !steps.contains("microsoft_office") { steps.append("microsoft_office") }
        guard !steps.isEmpty else { return }

        let password = sudoPassword ?? sessionSudoPassword
        let effectivePassword: String? = (password == "") ? nil : password

        // Remember exactly which apps this aggregate run was asked to update, by
        // bundle id + friendly name. topgrade batches its work by source and
        // exits 0 even when individual apps fail, so we can't read a clean
        // per-app result from its output. Instead we reconcile AFTER the post-run
        // rescan: any app we attempted that STILL shows an available update
        // didn't actually update — those are the failures to surface.
        let attempted: [(bundleID: String, name: String)] =
            updates.map { ($0.bundleID, $0.appName) }

        appUpdateProgress[key] = InstallProgress(phase: .preparing, log: [])
        let task = Task { [weak self] in
            guard let self else { return }
            let stream = TopgradeService.shared.run(steps: steps, sudoPassword: effectivePassword)
            for await line in stream {
                self.appUpdateProgress[key]?.log.append(line)
                if let phase = InstallProgress.phase(forLine: line) {
                    self.appUpdateProgress[key]?.phase = phase
                }
            }
            self.finishAppUpdate(key: key)
            await self.refreshAppUpdates()
            // Reconcile per-app outcomes now that the inventory is fresh. Apps
            // that dropped out of the updates list succeeded; any still listed
            // failed to update in place — record them so the persistent
            // "some apps can't be updated here" banner names them, instead of
            // the run finishing silently with no feedback at all.
            self.reconcileAllAppUpdateOutcome(attempted: attempted)
        }
        appUpdateTasks[key] = task
    }

    // After an aggregate "Update All Apps" run + rescan, compares the apps we
    // attempted against the apps that still have an available update. Any app
    // still listed didn't update in place, so we flag it on the error banner
    // (and clear the flag for the ones that succeeded). Without this the
    // aggregate run gives no error feedback even when an app can't be updated.
    private func reconcileAllAppUpdateOutcome(attempted: [(bundleID: String, name: String)]) {
        guard !attempted.isEmpty else { return }
        let stillUpdatable = Set(AppUpdateService.shared.updates.map { $0.bundleID })
        for app in attempted {
            if stillUpdatable.contains(app.bundleID) {
                AppUpdateService.shared.recordUpdateError(bundleID: app.bundleID, appName: app.name)
            } else {
                AppUpdateService.shared.clearUpdateError(bundleID: app.bundleID)
            }
        }
    }

    // Settle an app-update HUD: mark failed (if the log shows an error) or done,
    // drop the backing task, and schedule the auto-clear.
    private func finishAppUpdate(key: String) {
        appUpdateTasks[key] = nil
        let log = appUpdateProgress[key]?.log ?? []
        let joined = log.joined(separator: "\n").lowercased()
        // topgrade exits 0 even when a step errors; detect failure from output.
        let failed = joined.contains("error:") || joined.contains("failed")
            || joined.contains("could not") || joined.contains("not permitted")
        if failed {
            let message = log.last(where: {
                let l = $0.lowercased()
                return l.contains("error") || l.contains("failed") || l.contains("not permitted")
            }) ?? "Update failed. Open the app or website to update manually."
            appUpdateProgress[key]?.phase = .failed(message)
            // Surface the "some apps can't be updated in place — park them"
            // banner on the Mac Store/Other Apps screen. Only for per-app runs
            // (the aggregate "Update All" key isn't a real bundle id). The HUD
            // auto-clears after a few seconds, but the banner persists until the
            // user parks the app or dismisses it, so the guidance isn't missed.
            if key != AppDataService.allAppsUpdateKey {
                let name = AppUpdateService.shared.allApps.first(where: { $0.bundleID == key })?.appName
                    ?? AppUpdateService.shared.updates.first(where: { $0.bundleID == key })?.appName
                    ?? key
                AppUpdateService.shared.recordUpdateError(bundleID: key, appName: name)
            }
        } else {
            appUpdateProgress[key]?.phase = .finished
            // A successful update clears any earlier error flag for this app.
            if key != AppDataService.allAppsUpdateKey {
                AppUpdateService.shared.clearUpdateError(bundleID: key)
            }
        }
        scheduleAppProgressClear(key: key)
    }

    // Clears a finished/failed app-update HUD after a short delay so the row
    // shows its final state briefly, then returns to normal.
    private func scheduleAppProgressClear(key: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            // Only clear if no NEW run started in the meantime.
            if self.appUpdateTasks[key] == nil {
                self.appUpdateProgress[key] = nil
            }
        }
    }

    private func appendLog(token: String, line: String) {
        installProgress[token]?.log.append(line)
    }

    private func setPhase(token: String, phase: InstallProgress.Phase) {
        installProgress[token]?.phase = phase
    }

    private func lastLogLine(token: String) -> String {
        installProgress[token]?.log.last ?? ""
    }

    // Best-effort human-readable failure message: prefer brew's explicit
    // `Error:`/`fatal:` line from the tail of the log; fall back to the last
    // non-empty line. Used to populate the .failed(message) phase.
    private func failureMessage(token: String) -> String {
        let all = (installProgress[token]?.log ?? [])
        // Scan the WHOLE log (newest first) for brew's explicit error marker.
        // brew often prints `Error:` EARLY and then many follow-on hint lines
        // (e.g. the "directories are not writable… sudo chown -R …" block, which
        // is ~30 lines), so an 8-line tail window misses it entirely and the
        // operation looks like it "did nothing." Scanning the full log surfaces
        // the real cause. brew indents continuation lines, so for the writable
        // -directories error we additionally fold in the first directory it
        // names to make the message actionable.
        if let idx = all.lastIndex(where: {
            let l = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return l.hasPrefix("error:") || l.hasPrefix("fatal:")
                || l.contains("installation failed") || l.contains("failed to")
        }) {
            let line = all[idx].trimmingCharacters(in: .whitespaces)
            // Special-case brew's multi-line "not writable" error so the HUD
            // shows a concise, fixable summary instead of just the bare header.
            if line.lowercased().contains("not writable") {
                return "Homebrew can’t write to its install directories. "
                    + "Run in Terminal:  sudo chown -R $(whoami) /opt/homebrew"
            }
            return line
        }
        return all.reversed().first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        })?.trimmingCharacters(in: .whitespaces) ?? "Operation failed"
    }

    private func logIndicatesFailure(token: String) -> Bool {
        // brew prints real failures with an `Error:` prefix (or `fatal:`), often
        // a few lines before the end (a warning line can follow). Scan the tail
        // of the log for those explicit markers rather than matching any line
        // that merely contains the substring "error" (e.g. a package named
        // "error-prone" or a benign "0 errors" summary), which produced false
        // failures before.
        // Scan the WHOLE log, not just the last 8 lines: brew prints `Error:`
        // EARLY for pre-flight failures (e.g. "directories are not writable")
        // and then ~30 follow-on hint lines, which pushed the marker out of an
        // 8-line tail window so the operation was treated as a success and the
        // HUD showed nothing. We still require the explicit `error:`/`fatal:`
        // prefix (not a bare "error" substring) to avoid false positives like a
        // package named "error-prone" or a "0 errors" summary line.
        let all = (installProgress[token]?.log ?? [])
        for raw in all {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("error:") || line.hasPrefix("fatal:")
                || line.contains("installation failed")
                || line.contains("failed to") {
                return true
            }
        }
        return false
    }

    // True when the log shows brew's shared-directory removal failure: an
    // `rmdir.sh ... exited with` line, with no OTHER unrelated hard error.
    //
    // This is the signature of the cask-upgrade abort we work around: some casks
    // (notably the Microsoft Office apps) share a support directory like
    // `/Library/Application Support/Microsoft` that holds the common
    // `MAU2.0/Microsoft AutoUpdate.app`. brew's upgrade removes the old version
    // first; its `rmdir.sh` (run under `set -euo pipefail`) exits non-zero on
    // that non-empty shared dir, which aborts the upgrade BEFORE the new version
    // is poured. Crucially this is NOT benign — the app does not actually
    // upgrade — so we must not mask it as success. Instead the install driver
    // uses this as the trigger to retry via a forced reinstall, which pours the
    // new version without the failing pre-removal step (we route problem
    // cask upgrades through `brew install --cask --force`).
    private func logIndicatesSharedDirCleanupFailure(token: String) -> Bool {
        let lines = installProgress[token]?.log ?? []
        var sawRmdirFailure = false
        for raw in lines {
            let line = raw.lowercased()
            // The specific signature: a failure that names rmdir.sh (brew's
            // shared-directory remover) and reports a non-zero exit.
            if line.contains("rmdir.sh") && line.contains("exited with") {
                sawRmdirFailure = true
                continue
            }
            // Any OTHER hard error means the failure isn't (only) the rmdir one,
            // so a forced reinstall wouldn't necessarily fix it — don't claim it.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if (trimmed.hasPrefix("error:") || trimmed.hasPrefix("fatal:")
                || trimmed.contains("installation failed")
                || trimmed.contains("failed to"))
                && !line.contains("rmdir.sh") {
                return false
            }
        }
        return sawRmdirFailure
    }

    // Logs the install/uninstall event (best-effort) and refreshes installed
    // state so installedByToken — read by every card — is current.
    private func logAndRefresh(token: String, action: String) async {
        do {
            try await db.logInstallEvent(token: token, type: .cask, action: action, version: nil)
        } catch {
            // Logging is best-effort; ignore failures.
        }
        await refreshInstalled()
    }

    // Marks an operation finished (or failed), clears its backing Task, and
    // schedules the progress entry to clear a few seconds later so the HUD can
    // show a brief success/failure state before disappearing.
    private func finish(token: String, failure: String?) {
        // Batch-managed success: keep the row visibly on "Cleaning up…" (the
        // batch is about to run one shared `brew cleanup` for all of them) and
        // do NOT schedule the auto-clear here — the batch clears it once the
        // shared cleanup finishes. Failures still fall through to the normal
        // failed-state handling below so the error surfaces immediately.
        if failure == nil && batchManagedClearTokens.contains(token) {
            installProgress[token]?.phase = .cleaningUp
            installTasks[token] = nil
            return
        }

        if let failure {
            installProgress[token]?.phase = .failed(failure)
            // A batch member that failed is no longer batch-managed for clearing;
            // let it clear on the normal timer like any other failure.
            batchManagedClearTokens.remove(token)
            // On failure, persist the full captured brew output to a log file so
            // the exact error (which otherwise lives only in memory and clears a
            // few seconds later) is recoverable for troubleshooting. Best-effort:
            // never let logging interfere with the operation result.
            writeFailureLog(token: token, failure: failure)
        } else {
            installProgress[token]?.phase = .finished
        }
        installTasks[token] = nil

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            // Only clear if no NEW operation started for this token in the meantime.
            if self.installTasks[token] == nil {
                self.installProgress[token] = nil
            }
        }
    }

    // Writes the full brew log for a failed operation to
    // ~/Library/Logs/ForgedBrew/<token>-<timestamp>.log. Best-effort and silent on
    // error. Gives a durable record of the exact failure (brew's full streamed
    // output, including any `Error:` / `rmdir.sh ... exited with` lines) that the
    // in-memory progress entry would otherwise drop after its brief display.
    private func writeFailureLog(token: String, failure: String) {
        let lines = installProgress[token]?.log ?? []
        guard !lines.isEmpty else { return }
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/ForgedBrew", isDirectory: true) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = logsDir.appendingPathComponent("\(token)-\(stamp).log")
        let header = """
        ForgedBrew operation failure log
        token: \(token)
        when: \(stamp)
        summary: \(failure)
        ----------------------------------------

        """
        let body = header + lines.joined(separator: "\n") + "\n"
        do {
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort only; ignore logging failures.
        }
    }

    // Sets homebrewVersion from BrewCLIService.brewVersion()
    // Called on app launch. Silently ignores errors.
    func fetchBrewVersion() async {
        // Fast filesystem check first — drives the first-run install sheet.
        brewMissing = !cli.isInstalled
        do {
            homebrewVersion = try await cli.brewVersion()
        } catch {
            // A thrown error here (e.g. executableNotFound) also means brew is
            // absent; keep brewMissing true so the sheet shows.
            homebrewVersion = ""
        }
    }

    // MARK: - Brewfile import / export

    // Returns Brewfile text for the current installed packages (for on-screen
    // preview). Pure formatting; no I/O.
    func brewfilePreview() -> String {
        BrewfileService.generate(from: installedPackages)
    }

    // Writes a Brewfile for the current installed packages to `url`.
    // Throws on write failure so the caller can surface it.
    func exportBrewfile(to url: URL) throws {
        let text = BrewfileService.generate(from: installedPackages)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // Reads and parses the Brewfile at `url`, then installs each entry in order,
    // streaming progress lines back to the caller. Formulae use
    // BrewCLIService.installFormula, casks use install(cask:); `tap` entries are
    // reported but not acted on (taps are implicit for core formulae/casks here).
    // Reuses the actor-safe stream pattern: the CLI is awaited inside the Task.
    // When everything finishes, installed state is refreshed once.
    func importBrewfile(from url: URL) -> AsyncStream<String> {
        AsyncStream<String> { continuation in
            let task = Task { [weak self, cli] in
                guard let self else { continuation.finish(); return }

                let contents: String
                do {
                    contents = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    continuation.yield("Error reading Brewfile: \(error.localizedDescription)")
                    continuation.finish()
                    return
                }

                let entries = BrewfileService.parse(contents)
                let installable = entries.filter { $0.kind != .tap }
                if installable.isEmpty {
                    continuation.yield("No formulae or casks found in this Brewfile.")
                    continuation.finish()
                    return
                }

                continuation.yield("Found \(installable.count) package(s) to install.")

                for entry in installable {
                    if Task.isCancelled { break }
                    let label = entry.kind == .cask ? "cask" : "formula"
                    continuation.yield("")
                    continuation.yield("==> Installing \(label) \(entry.name)")

                    let source: AsyncStream<String>
                    switch entry.kind {
                    case .cask:
                        source = await cli.install(cask: entry.name)
                    case .brew:
                        source = await cli.installFormula(entry.name)
                    case .tap:
                        continue
                    }
                    for await line in source {
                        continuation.yield(line)
                    }
                }

                // Deep-clean the download cache after a bulk import. A large
                // Brewfile pulls down many bottles/installers; brew keeps those
                // in its cache, so we run the same Deep Clean the Maintenance
                // screen offers (`brew cleanup --prune=all -s -v`) to reclaim
                // that space immediately rather than leaving it for the user to
                // clean up manually. Reported as its own phase so the UI can show
                // "Cleaning up…". Skipped if the import was cancelled.
                if !Task.isCancelled {
                    continuation.yield("")
                    continuation.yield("==> Cleaning up cache")
                    let cleanup = await cli.deepCleanup()
                    for await line in cleanup {
                        continuation.yield(line)
                    }
                }

                continuation.yield("")
                continuation.yield("Done.")
                continuation.finish()
                await self.refreshInstalled()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private helpers

    // Starts the source CLI stream (via the supplied async closure, since the CLI
    // is actor-isolated and must be awaited), iterates it once, and forwards every
    // line into a new stream returned to the caller. When the source finishes, logs
    // the event and refreshes installed state on the main actor.
    private func relay(
        token: String,
        type: PackageType,
        action: String,
        start: @escaping @Sendable () async -> AsyncStream<String>
    ) -> AsyncStream<String> {
        AsyncStream<String> { continuation in
            let task = Task { [weak self] in
                let source = await start()
                for await line in source {
                    continuation.yield(line)
                }
                continuation.finish()

                guard let self else { return }
                do {
                    try await self.db.logInstallEvent(
                        token: token, type: type, action: action, version: nil
                    )
                } catch {
                    // Logging is best-effort; ignore failures.
                }
                await self.refreshInstalled()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
