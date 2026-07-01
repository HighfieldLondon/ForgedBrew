//
//  MaintenanceMetrics.swift
//  ForgedBrew
//
//  MaintenanceMetrics — the @MainActor @Observable view-model behind the whole
//  Maintenance screen. It owns every asynchronously-probed value: the brew-doctor
//  report, cache sizes, Homebrew's version, and the results of each on-demand scan
//  (orphans, duplicates, disk usage, quarantine, adopt candidates, the local
//  security scan, the network CVE scan, and the Gatekeeper "trust" scan). Split
//  out of MaintenanceView.swift; also carries AdoptOutcome, the classified adopt
//  result the UI renders. Pure code motion.
//
//  Every probe is best-effort — it degrades to a neutral state on failure and
//  never throws into the UI. A few patterns recur, worth knowing before reading
//  the methods:
//    • a `scanning` Bool (drives spinners / disables buttons), cleared on every
//      exit path — several use `defer` so a Task cancelled when its sheet is
//      dismissed mid-scan can't leave the flag stuck true;
//    • a re-entrancy guard (`guard !scanning`) so overlapping Tasks don't fight
//      over the live progress counters;
//    • live progress callbacks (scanned / total / current item), invoked on the
//      main actor so the sheet updates app-by-app;
//    • per-row error dictionaries keyed by token / path / install-id so a failed
//      action surfaces its reason inline instead of being swallowed.
//
//  Persistence & freshness: the Security and Trust scans are slow, so the last
//  completed report is written to Application Support and reloaded on init.
//  Reopening a scan screen shows the saved results immediately; a scan only
//  auto-re-runs once its result is older than `scanFreshness` (24h), or on a
//  forced Re-scan.
//

import SwiftUI
import AppKit

/// The classified result of an adopt attempt, so the UI can show the right icon,
/// colour, and message — and decide whether to offer the Force fallback. The
/// associated `String` is the user-facing message; `adoptSummary(_:)` maps brew's
/// raw output onto one of these cases.
nonisolated enum AdoptOutcome: Equatable, Sendable {
    case success(String)        // adopted cleanly
    case mismatch(String)       // already installed / version mismatch — Force may help
    case failure(String)        // a real failure (e.g. OneDrive is Microsoft-controlled)
    case unknown(String)        // finished without a clear signal — suggest re-scan

    var message: String {
        switch self {
        case .success(let m), .mismatch(let m), .failure(let m), .unknown(let m): return m
        }
    }
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var isMismatch: Bool { if case .mismatch = self { return true }; return false }
    var isFailure: Bool { if case .failure = self { return true }; return false }
}

/// The view-model backing the entire Maintenance screen. It is `@MainActor`
/// (every property mutation happens on the main actor, so progress callbacks
/// from the off-actor scanners can write straight to these `@Observable`
/// properties and the UI reflects them live) and `@Observable` (SwiftUI tracks
/// reads automatically). One instance is created by `MaintenanceView` and shared
/// into every sheet, so a scan kicked off from a card is visible in its sheet.
/// See the file header for the shared scan/load/persistence conventions.
@MainActor
@Observable
final class MaintenanceMetrics {
    var brewCacheSize: String? = nil          // e.g. "55 MB"
    var brewCacheSizeAfter: String? = nil     // populated after a cleanup run
    var doctorReport: BrewCLIService.DoctorReport? = nil
    var doctorLoading = false
    var forgedbrewCacheSize: String? = nil

    // Quarantine (Gatekeeper) management state.
    var quarantinedItems: [BrewCLIService.QuarantinedItem] = []
    var quarantineScanning = false
    var quarantineRemoving = false
    // Last removal outcome surfaced in the sheet: how many cleared, and any
    // paths that failed (usually a Full Disk Access / permissions issue). nil
    // until a removal has run.
    var quarantineError: String? = nil
    var quarantineLastCleared: Int = 0

    // Adopt (bring an existing app under Homebrew management) state.
    var adoptCandidates: [BrewCLIService.AdoptCandidate] = []
    var adoptScanning = false
    var adoptingTokens = Set<String>()        // tokens with an adopt in flight
    // Per-token last-run outcome, so a row can surface a clear result / error
    // (success, version mismatch, or a real failure like OneDrive) right under
    // itself with the right icon and color.
    var adoptResults: [String: AdoptOutcome] = [:]
    // Tokens the user chose to hide from Adopt. Persisted in UserDefaults so the
    // choice survives relaunches; mirrored here for instant @Observable updates.
    var hiddenAdoptTokens: Set<String> = []

    // Duplicates (same app/tool installed more than once) state.
    var duplicateGroups: [DuplicateGroup] = []
    var duplicatesScanning = false
    var removingDuplicateIDs = Set<String>()   // install ids with a removal in flight
    // Per-install last-removal error, keyed by DuplicateInstall.id, so a row can
    // show exactly why a removal failed (permissions, app running, brew error).
    var duplicateErrors: [String: String] = [:]

    // Full Disk Access status. Probed on appear so the banner can prompt the
    // user to grant access (without which cache cleanup + sizes are unreliable).
    var fdaGranted: Bool = false

// Probes whether ForgedBrew has Full Disk Access. Drives the banner that
    // prompts the user to grant it (without which cache cleanup and quarantine
    // removal silently fail).
func loadFDAStatus() async {
        fdaGranted = FullDiskAccess.isGranted()
    }

    // MARK: - Homebrew self-update
    //
    // We surface Homebrew's OWN version (separate from the packages it manages)
    // and a one-tap "Update Homebrew" that runs `brew update` -- the command
    // that fetches the newest Homebrew itself plus all formula/cask definitions.
    // There is no separate "upgrade Homebrew" command, and Homebrew updates by
    // pulling git commits (not just tagged releases), so we do NOT try to predict
    // whether an update is needed from a version comparison -- that is unreliable
    // and can be misleading. Instead, like the established Homebrew GUIs, we treat
    // Update as a refresh action and report whatever `brew update` actually did.
    var brewInstalledVersion: String? = nil   // e.g. "4.4.24"; nil = unknown/not installed
    var brewVersionLoading: Bool = false      // true while probing the installed version
    var brewUpdating: Bool = false            // true while `brew update` runs
    var brewUpdateMessage: String? = nil      // last result line from `brew update`, for the banner

    // Reads the installed Homebrew version via the CLI. Leaves brewInstalledVersion
    // nil if brew is missing or unparseable, which the banner shows as "not found".
    func loadHomebrewStatus(cli: BrewCLIService) async {
        brewVersionLoading = true
        brewInstalledVersion = await cli.installedBrewVersion()
        brewVersionLoading = false
    }

    // Runs `brew update`, then re-reads the installed version and reports a
    // CLEAN, deterministic outcome. We do NOT echo raw brew output lines: when
    // brew has changes it prints section headers ("==> Updated Casks") followed
    // by one bare cask/formula name per line, so the last non-empty line is
    // often just an app name (e.g. "kimi-code") -- meaningless as a status. We
    // instead detect the "Already up-to-date." sentinel and otherwise summarize.
    @MainActor
    func updateHomebrew(cli: BrewCLIService) async {
        guard !brewUpdating else { return }
        brewUpdating = true
        brewUpdateMessage = "Updating Homebrew…"
        var lines: [String] = []
        for await line in await cli.updateBrew() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        // Re-read the version in case Homebrew itself advanced.
        brewInstalledVersion = await cli.installedBrewVersion()
        brewUpdating = false

        let joined = lines.joined(separator: "\n")
        // An explicit error (e.g. permissions) should be shown verbatim so the
        // user knows what to fix.
        if let errorLine = lines.first(where: { $0.hasPrefix("Error:") || $0.hasPrefix("Warning:") }) {
            brewUpdateMessage = errorLine
        } else if joined.localizedCaseInsensitiveContains("already up-to-date")
                    || joined.localizedCaseInsensitiveContains("already up to date") {
            brewUpdateMessage = "Homebrew is up to date."
        } else if lines.contains(where: { $0.range(of: #"Updated \d+ tap"#, options: .regularExpression) != nil }) {
            brewUpdateMessage = "Homebrew and package definitions updated."
        } else {
            brewUpdateMessage = "Homebrew updated."
        }
    }

    // Measures the current Homebrew download-cache size (the "before" figure).
    func loadCacheSize(cli: BrewCLIService) async {
        brewCacheSize = (try? await cli.cacheSize()) ?? nil
    }

    // Re-measures the cache after a cleanup so the card can show "was X, now Y".
    func refreshCacheAfterCleanup(cli: BrewCLIService) async {
        brewCacheSizeAfter = (try? await cli.cacheSize()) ?? nil
    }

    // Runs `brew doctor` (via the CLI parser) and stores the structured report
    // so the Doctor section and health summary can render its findings.
    func loadDoctor(cli: BrewCLIService) async {
        doctorLoading = true
        doctorReport = await cli.doctorReport()
        doctorLoading = false
    }

    // Tracks which tap actions (trust / untap) are currently running, plus any
    // error message to surface beside a tap card when the action
    // fails (e.g. untap blocked because installed packages still depend on it).
    var tapActionInFlight = Set<String>()
    var tapActionErrors: [String: String] = [:]
    // Name of the tap awaiting Remove-Tap confirmation, if any. Drives a
    // confirmation dialog so the destructive untap isn't a one-click accident.
    var tapPendingUntap: String? = nil

    // Trusts a tap, then re-runs brew doctor on success so the now-trusted tap
    // drops out of the warning. On failure we keep the card and show why.
    func trustTap(_ name: String, cli: BrewCLIService) async {
        tapActionErrors[name] = nil
        tapActionInFlight.insert(name)
        let result = await cli.trustTap(name)
        tapActionInFlight.remove(name)
        if result.success {
            await loadDoctor(cli: cli)
        } else {
            tapActionErrors[name] = result.message.isEmpty
                ? "Could not trust this tap." : result.message
        }
    }

    // Removes a tap entirely, then re-runs brew doctor on success. brew refuses
    // to untap when installed packages still depend on it; that message is shown
    // verbatim so the user knows to remove those packages first.
    func untapTap(_ name: String, cli: BrewCLIService) async {
        tapActionErrors[name] = nil
        tapActionInFlight.insert(name)
        let result = await cli.untap(name)
        tapActionInFlight.remove(name)
        if result.success {
            await loadDoctor(cli: cli)
        } else {
            tapActionErrors[name] = result.message.isEmpty
                ? "Could not untap this tap." : result.message
        }
    }

    func loadQuarantinedItems(cli: BrewCLIService) async {
        quarantineScanning = true
        // Clear the flag on every exit path (including Task cancellation when
        // the sheet is dismissed mid-scan) so the view can never get stuck
        // showing "Scanning…".
        defer { quarantineScanning = false }
        quarantinedItems = await cli.scanQuarantinedItems()
    }

    // Scans for duplicates using the current cask catalog plus the installed
    // cask/formula token sets (derived from AppDataService.installedPackages).
    func loadDuplicates(casks: [CaskMetadata],
                        installedCaskTokens: Set<String>,
                        installedFormulaTokens: Set<String>,
                        cli: BrewCLIService) async {
        duplicatesScanning = true
        // Clear the flag on every exit path (including Task cancellation when
        // the sheet is dismissed mid-scan) so the view can never get stuck
        // showing "Scanning…". Mirrors loadQuarantinedItems.
        defer { duplicatesScanning = false }
        duplicateGroups = await cli.scanDuplicates(
            casks: casks,
            installedCaskTokens: installedCaskTokens,
            installedFormulaTokens: installedFormulaTokens
        )
    }

    // Removes one copy of a duplicate, then re-scans so the resolved group drops
    // out of the list. Any failure is surfaced on the row via duplicateErrors
    // (keyed by the install id) and the group stays visible so the user sees why.
    func removeDuplicate(_ install: DuplicateInstall,
                         casks: [CaskMetadata],
                         installedCaskTokens: Set<String>,
                         installedFormulaTokens: Set<String>,
                         cli: BrewCLIService) async {
        removingDuplicateIDs.insert(install.id)
        duplicateErrors[install.id] = nil
        let error = await cli.removeDuplicateInstall(install)
        removingDuplicateIDs.remove(install.id)
        if let error {
            duplicateErrors[install.id] = error
            return   // keep the group visible with its error
        }
        // Success — re-scan so the group disappears (or shrinks) accordingly.
        await loadDuplicates(casks: casks,
                             installedCaskTokens: installedCaskTokens,
                             installedFormulaTokens: installedFormulaTokens,
                             cli: cli)
    }

    // Orphaned packages (formulae kept only as now-unneeded dependencies) state.
    var orphanResult: OrphanScanResult = .empty
    var orphansScanning = false
    var removingOrphanTokens = Set<String>()   // formula tokens with a removal in flight
    var removingAllOrphans = false             // "Remove All" / autoremove in flight
    // Per-package last-removal error, keyed by formula token, so a row can show
    // exactly why a removal failed (e.g. still has dependents).
    var orphanErrors: [String: String] = [:]
    // A top-level error for the "Remove All" path (autoremove as a whole).
    var orphanRemoveAllError: String?

    // Asks Homebrew which formulae are orphaned and enriches each with size.
    func loadOrphans(cli: BrewCLIService) async {
        orphansScanning = true
        // Clear on every exit path (including Task cancellation mid-scan) so the
        // view can never get stuck showing "Scanning…". Mirrors loadQuarantinedItems.
        defer { orphansScanning = false }
        orphanResult = await cli.scanOrphanedPackages()
    }

    // Removes one orphaned formula, then re-scans so the list refreshes (and
    // any newly-exposed orphans surface). Failure is surfaced on the row via
    // orphanErrors (keyed by token) and the package stays visible.
    func removeOrphan(_ package: OrphanedPackage, cli: BrewCLIService) async {
        removingOrphanTokens.insert(package.token)
        orphanErrors[package.token] = nil
        let error = await cli.removeOrphanedPackage(package)
        removingOrphanTokens.remove(package.token)
        if let error {
            orphanErrors[package.token] = error
            return   // keep the package visible with its error
        }
        await loadOrphans(cli: cli)
    }

    // Removes every orphaned formula in one shot via `brew autoremove`, then
    // re-scans. Any failure is surfaced via orphanRemoveAllError.
    func removeAllOrphans(cli: BrewCLIService) async {
        removingAllOrphans = true
        orphanRemoveAllError = nil
        let error = await cli.removeAllOrphanedPackages()
        removingAllOrphans = false
        if let error {
            orphanRemoveAllError = error
            return
        }
        await loadOrphans(cli: cli)
    }

    // Trust Management Screening (upcoming Homebrew change) state. Every installed cask
    // app that macOS Gatekeeper rejects today — these are at risk after Sept 1,
    // 2026, when Homebrew stops working around Gatekeeper for casks and drops
    // those that fail it. Includes apps with no quarantine flag (still at risk,
    // just no local action yet); the sheet splits actionable vs. watch-only.
    var gatekeeperRiskResult: GatekeeperRiskScanResult = .empty
    var trustScanning = false
    var trustHasScanned = false
    // Live progress for the trust scan: how many apps checked out of the total,
    // and the name of the app currently being assessed. Drives the sheet's
    // "Scanning X of N…" bar (same pattern as the Security Scan).
    var trustScannedCount = 0
    var trustTotalCount = 0
    var trustCurrentApp: String? = nil
    // Bundle paths with a trust action (xattr -d) in flight.
    var trustingPaths = Set<String>()
    // Per-app last-trust error, keyed by bundle path, so a row can show exactly
    // why clearing the quarantine flag failed.
    var trustErrors: [String: String] = [:]

    // How long a completed scan stays "fresh". While fresh, reopening a scan
    // screen shows the saved results instead of auto-re-running. Re-scan always
    // overrides this.
    static let scanFreshness: TimeInterval = 24 * 60 * 60   // 24 hours

    // True when the last Security Scan finished within the freshness window.
    // `timeIntervalSinceNow` is NEGATIVE for a past date, so a scan that ran less
    // than `scanFreshness` ago compares as "> -scanFreshness". We ALSO require the
    // timestamp not be in the future (`<= Date()`): a clock change or hand-edited
    // cache could leave a future date, which would otherwise read as "fresh"
    // indefinitely and suppress the auto-rescan forever. A future date is treated
    // as stale so a rescan runs. `loadSecurityScan` checks this to skip an auto-re-run.
    var securityIsFresh: Bool {
        securityHasScanned
            && securityScannedAt.timeIntervalSinceNow > -Self.scanFreshness
            && securityScannedAt <= Date()
    }
    // True when the last Trust scan finished within the freshness window. The
    // Trust scan stores its own timestamp on the result struct rather than a
    // separate property, so we read it from there. Same future-date guard as
    // above: a future timestamp is treated as stale so a rescan runs.
    var trustIsFresh: Bool {
        trustHasScanned
            && gatekeeperRiskResult.scannedAt.timeIntervalSinceNow > -Self.scanFreshness
            && gatekeeperRiskResult.scannedAt <= Date()
    }

    // Scans installed cask apps and keeps only the ones Gatekeeper would reject
    // today — the apps at risk from the upcoming Homebrew cask-quarantine change.
    // `force: true` (the Re-scan button, and the post-trustApp re-scan) bypasses
    // the freshness gate; otherwise a fresh saved result is reused as-is.
    func loadGatekeeperRisks(cli: BrewCLIService, force: Bool = false) async {
        // Re-entrancy guard. Several paths can ask for a scan (the Review
        // button, Re-scan, and trustApp re-scans when done).
        // Without this, overlapping Tasks each reset the counter to 0 and start
        // a fresh pass, so the progress bar appears to climb, snap back, climb
        // higher, snap back, etc. Bail out if a scan is already running.
        guard !trustScanning else { return }
        if !force && trustIsFresh { return }            // reuse saved results (new)
        trustScanning = true
        trustScannedCount = 0
        trustTotalCount = 0
        trustCurrentApp = nil
        // GUARANTEE the scanning flag is cleared on EVERY exit path — including
        // when this Task is cancelled mid-scan (e.g. the sheet is dismissed
        // while "Scanning…" is showing). Previously the `trustScanning = false`
        // line lived after the await, so a cancellation skipped it and left the
        // flag stuck true forever; the re-entrancy guard above then turned every
        // later Re-scan into a silent no-op that just spun on "Scanning…". The
        // defer runs even on cancellation, so the scan can always be re-run.
        defer {
            trustScanning = false
            trustCurrentApp = nil
        }
        // Walk apps one-by-one and update the live progress as each is checked.
        // The callback runs on the main actor, so it can mutate this @Observable
        // state directly and the sheet reflects it immediately.
        gatekeeperRiskResult = await cli.scanGatekeeperRisks { [weak self] scanned, total, currentApp in
            guard let self else { return }
            self.trustScannedCount = scanned
            self.trustTotalCount = total
            self.trustCurrentApp = currentApp.isEmpty ? nil : currentApp
        }
        // Persist after the assignment so a cancelled scan (which leaves the
        // result unchanged) doesn't overwrite the saved report with a partial.
        saveTrustScan()
        // Mark complete only on the real-completion path (NOT in the defer above),
        // matching loadSecurityScan: a Task cancelled mid-scan must not flip this
        // on while gatekeeperRiskResult is still empty, which would render the
        // reassuring "Nothing at risk" copy on a partial/aborted scan.
        trustHasScanned = true
    }

    // Clears the quarantine flag on one trusted app (xattr -d com.apple.quarantine
    // via removeQuarantine(at:)), then re-scans so the now-trusted app drops out
    // of the list. Failure is surfaced on the row via trustErrors (keyed by
    // bundle path) and the app stays visible.
    func trustApp(_ risk: GatekeeperRisk, cli: BrewCLIService) async {
        trustingPaths.insert(risk.appPath)
        trustErrors[risk.appPath] = nil
        let ok = await cli.removeQuarantine(at: risk.appPath)
        trustingPaths.remove(risk.appPath)
        if !ok {
            trustErrors[risk.appPath] = "Couldn’t clear the quarantine flag for this app."
            return   // keep the app visible with its error
        }
        await loadGatekeeperRisks(cli: cli, force: true)
    }

    // Disk footprint (Apps / Formulae / Caskroom / cache / taps) state.
    var diskFootprint: DiskFootprint = .empty
    var footprintMeasuring = false

    // Measures the Homebrew footprint. Slow-ish (du over the Cellar/Caskroom),
    // so it runs off the main actor inside the service and we just await the
    // result. `caskAppsBytes` is the summed size of cask-installed app bundles
    // in /Applications (those live outside the prefix); the caller computes it
    // from the per-cask sizes already on InstalledPackage and passes it in.
    func loadDiskFootprint(cli: BrewCLIService, caskAppsBytes: Int64) async {
        footprintMeasuring = true
        // Clear on every exit path (including Task cancellation mid-measure) so
        // the view can never get stuck showing "Measuring…". Mirrors loadQuarantinedItems.
        defer { footprintMeasuring = false }
        diskFootprint = await cli.measureDiskFootprint(caskAppsBytes: caskAppsBytes)
    }

    // MARK: - Security scan

    // Results accumulate HERE as each app is scanned, so the UI can show app-by-
    // app progress live rather than waiting for the whole batch. The sheet reads
    // this array directly (sorting itself), and we build a SecurityScanReport
    // from it at the end for the summary counts.
    var securityResults: [AppSecurityResult] = []
    // True while a scan is running (drives the spinner + disabled button).
    var securityScanning = false
    // True once a scan has completed at least once this session.
    var securityHasScanned = false
    // Set if the scan couldn't run at all (no installed casks, tooling error).
    var securityError: String? = nil
    // Live progress: how many apps we've scanned out of the total, and the name
    // of the app currently being scanned (shown under the progress bar).
    var securityScannedCount = 0
    var securityTotalCount = 0
    var securityCurrentApp: String? = nil
    // When the most recent completed scan finished (for the report summary).
    var securityScannedAt: Date = .distantPast

    // A live view of the results gathered so far, wrapped in a report so the
    // sheet can reuse its sorting + counts during AND after the scan.
    var securityReport: SecurityScanReport {
        SecurityScanReport(results: securityResults, scannedAt: securityScannedAt)
    }

    // MARK: - Vulnerability (CVE) scan
    //
    // Layer 2 of Diagnostics. Unlike the security scan, this reaches the network
    // (OSV.dev) to check whether the installed VERSION of each package has known
    // CVEs. Results accumulate live, package-by-package, just like the security
    // scan above.
    var vulnResults: [PackageVulnerabilityResult] = []
    var vulnScanning = false
    var vulnHasScanned = false
    var vulnError: String? = nil
    var vulnScannedCount = 0
    var vulnTotalCount = 0
    var vulnCurrentPkg: String? = nil
    var vulnScannedAt: Date = .distantPast

    var vulnReport: VulnerabilityScanReport {
        VulnerabilityScanReport(results: vulnResults, scannedAt: vulnScannedAt)
    }

    // Runs the CVE scan across every installed formula and cask, querying OSV
    // for each and appending results AS THEY COMPLETE so the UI updates live.
    // This is the only ForgedBrew feature that uses the network.
    func loadVulnerabilityScan(cli: BrewCLIService) async {
        vulnScanning = true
        // Clear on every exit path (the empty-targets guard below AND Task
        // cancellation mid-scan) so the view can never get stuck showing
        // "Scanning…". Mirrors loadQuarantinedItems.
        defer { vulnScanning = false }
        vulnError = nil
        vulnResults = []
        vulnScannedCount = 0
        vulnCurrentPkg = nil

        let targets = (try? await cli.vulnerabilityScanTargets()) ?? []
        vulnTotalCount = targets.count

        guard !targets.isEmpty else {
            vulnHasScanned = true
            vulnError = "No installed packages were found to check."
            vulnScannedAt = Date()
            return
        }

        // Sort so formulae then casks, alphabetically within each, for a stable
        // predictable progression in the UI.
        let ordered = targets.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        for target in ordered {
            vulnCurrentPkg = target.name
            let result = await cli.scanPackageVulnerabilities(target: target)
            vulnResults.append(result)
            vulnScannedCount += 1
        }

        vulnCurrentPkg = nil
        vulnScannedAt = Date()
        vulnHasScanned = true
    }

    // Runs the local security scan across every installed cask app bundle,
    // appending each app's result AS IT COMPLETES so the UI updates live. No
    // network access — this only uses macOS's own codesign + spctl tooling.
    // `force: true` (Re-scan) bypasses the freshness gate; otherwise a saved
    // result that is still fresh is reused without re-scanning. A completed result
    // (when casks were found) is persisted so reopening the screen shows it
    // immediately; the empty "no casks found" outcome is intentionally NOT
    // persisted (see the guard below).
    func loadSecurityScan(cli: BrewCLIService, force: Bool = false) async {
        if securityScanning { return }                 // re-entrancy guard
        if !force && securityIsFresh { return }         // reuse fresh saved results
        securityScanning = true
        // Clear the scanning flag (and the live "current app") on EVERY exit path —
        // including Task cancellation when the sheet is dismissed mid-scan — so the
        // re-entrancy guard above can never latch true forever and turn every later
        // scan into a silent no-op. Mirrors loadGatekeeperRisks. (securityHasScanned
        // and saveSecurityScan stay on the real-completion path below, so a cancelled
        // partial scan is neither marked complete nor persisted.)
        defer {
            securityScanning = false
            securityCurrentApp = nil
        }
        securityError = nil
        securityResults = []
        securityScannedCount = 0
        securityCurrentApp = nil

        let bundles = await cli.installedAppBundlesToSecurityScan()
        securityTotalCount = bundles.count

        guard !bundles.isEmpty else {
            securityHasScanned = true
            securityError = "No installed apps were found to scan."
            securityScannedAt = Date()
            // Deliberately NOT persisted: a saved empty report would reload as a
            // misleading "All 0 apps passed" because securityError isn't part of
            // SecurityScanReport. Re-running an empty scan next launch is cheap and
            // shows the correct "no casks found" message.
            return
        }

        // Scan sequentially so results appear one-by-one, sorted A–Z by app name
        // (non-cask apps use their bundle PATH as the token, so we can't sort on
        // the token). Each scan is a few quick subprocesses; results are cached for
        // 24h, so the larger "all installed apps" sweep only re-runs occasionally.
        for bundle in bundles.sorted(by: {
            let a = (($0.appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let b = (($1.appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }) {
            // Show which app we're on (derive a friendly name from the path).
            let name = ((bundle.appPath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            securityCurrentApp = name
            let result = await cli.scanAppSecurity(token: bundle.token, appPath: bundle.appPath)
            securityResults.append(result)
            securityScannedCount += 1
        }

        securityScannedAt = Date()
        securityHasScanned = true
        saveSecurityScan()
    }

    // Removes quarantine from the given paths, then re-scans so the list and
    // any count reflect what's left. We now track which paths FAILED (each
    // removeQuarantine returns a Bool) and surface a clear error instead of
    // silently swallowing failures — the common cause is missing Full Disk
    // Access, which the user needs to be told about.
    func removeQuarantine(paths: [String], cli: BrewCLIService) async {
        quarantineRemoving = true
        quarantineError = nil
        var failed: [String] = []
        for path in paths {
            let ok = await cli.removeQuarantine(at: path)
            if !ok { failed.append((path as NSString).lastPathComponent) }
        }
        quarantineLastCleared = paths.count - failed.count
        if failed.isEmpty {
            quarantineError = nil
        } else if failed.count == paths.count {
            quarantineError = "Couldn't clear quarantine on \(failed.count) item\(failed.count == 1 ? "" : "s"). This usually means ForgedBrew needs Full Disk Access (see the banner above)."
        } else {
            quarantineError = "Cleared \(quarantineLastCleared), but \(failed.count) failed (\(failed.prefix(3).joined(separator: ", "))\(failed.count > 3 ? "…" : "")). Granting Full Disk Access usually fixes this."
        }
        quarantinedItems = await cli.scanQuarantinedItems()
        quarantineRemoving = false
    }

    // MARK: - Adopt

    // UserDefaults key for the persisted hidden-from-Adopt token list.
    private static let hiddenAdoptKey = "forgedbrewHiddenAdoptTokens"

    // Loads the persisted hidden list into memory. Call before the first scan.
    func loadHiddenAdoptTokens() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.hiddenAdoptKey) ?? []
        hiddenAdoptTokens = Set(stored)
    }

    private func persistHiddenAdoptTokens() {
        UserDefaults.standard.set(Array(hiddenAdoptTokens).sorted(), forKey: Self.hiddenAdoptKey)
    }

    // Scans for apps that could be adopted into Homebrew. Excludes apps Homebrew
    // already manages (from the Installed list) and anything the user hid.
    //
    // IMPORTANT: the "already managed" exclusion is only correct if the Installed
    // list has actually loaded. On a fresh launch the user can open Adopt before
    // appData.installedPackages has been populated; with an empty managed set the
    // filter excludes nothing and nearly every app that maps to a cask floods the
    // list. So we guarantee the Installed list is loaded first and derive the
    // managed-cask tokens from that fresh data instead of trusting a caller
    // snapshot that may be empty.
    func loadAdoptCandidates(casks: [CaskMetadata], managedTokens: Set<String>, cli: BrewCLIService, appData: AppDataService) async {
        adoptScanning = true
        // Always refresh the hidden set from persistence BEFORE scanning so the
        // exclusion is correct regardless of who triggers the scan or when. The
        // previous load happened in a separate .task, so a row-initiated Adopt
        // could scan with an empty hidden set and leak hidden apps into the
        // adoptable list (showing them in both the top list and the hidden
        // section). Reloading here closes that race.
        loadHiddenAdoptTokens()
        // Ensure the Installed list is loaded before we compute exclusions. If it
        // has never loaded (empty and not already in flight), load it now.
        if appData.installedPackages.isEmpty && !appData.isLoadingInstalled {
            await appData.refreshInstalled()
        }
        // Recompute managed cask tokens from the (now-loaded) Installed list so
        // the exclusion is always accurate, regardless of what the caller passed.
        let resolvedManaged = Set(
            appData.installedPackages
                .filter { $0.type == .cask }
                .map(\.token)
        )
        adoptCandidates = await cli.scanAdoptableApps(
            casks: casks,
            managedTokens: resolvedManaged,
            hiddenTokens: hiddenAdoptTokens
        )
        adoptScanning = false
    }

    // Adopts one app. Drains the brew stream, then re-scans (with the same
    // exclusions) so a freshly-adopted app drops off the list. The caller must
    // refresh the Installed list afterward so the adopted token is recognized as
    // managed on the next scan; we keep a local managedTokens snapshot here.
    func adopt(
        token: String,
        force: Bool,
        casks: [CaskMetadata],
        managedTokens: Set<String>,
        cli: BrewCLIService,
        appData: AppDataService
    ) async {
        adoptingTokens.insert(token)
        adoptResults[token] = nil
        var lines: [String] = []
        // BrewCLIService is an actor: hop to it to build the stream, THEN drain.
        let stream = await cli.adoptCask(token: token, force: force)
        for await line in stream { lines.append(line) }
        let outcome = Self.adoptSummary(lines)
        adoptResults[token] = outcome
        adoptingTokens.remove(token)
        // Only a clean success removes the app from the list. On mismatch or a
        // real failure (e.g. OneDrive, which Microsoft controls) we KEEP the row
        // so its error stays visible and the user can try Force or hide it.
        guard outcome.isSuccess else { return }
        // Keep the green "Adopted successfully" message visible for a few
        // seconds so the user sees confirmation, THEN drop the row so they do
        // not think they still need to adopt it again. We remove just this one
        // candidate immediately (cheap, animatable) and re-scan in the
        // background to keep the exclusion list correct for everything else.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        withAnimation(.easeInOut(duration: 0.25)) {
            adoptCandidates.removeAll { $0.suggestedToken == token }
        }
        adoptResults[token] = nil
        var managed = managedTokens
        managed.insert(token)
        await loadAdoptCandidates(casks: casks, managedTokens: managed, cli: cli, appData: appData)
    }

    // Hides a token from Adopt (persisted) and removes it from the current list.
    func hideAdopt(token: String) {
        hiddenAdoptTokens.insert(token)
        persistHiddenAdoptTokens()
        adoptCandidates.removeAll { $0.suggestedToken == token }
    }

    // Unhides a token; the next scan can surface it again.
    func unhideAdopt(token: String) {
        hiddenAdoptTokens.remove(token)
        persistHiddenAdoptTokens()
    }

    // Classifies brew's adopt output into a structured outcome. Order matters:
    // we check explicit failures BEFORE the generic "error" catch so a clear
    // message wins, and check success last among the positive signals.
    static func adoptSummary(_ lines: [String]) -> AdoptOutcome {
        let joined = lines.joined(separator: "\n").lowercased()

        // Real failures we don't want to mask as a mismatch. Apps whose cask is
        // managed/blocked by the vendor (OneDrive, some Microsoft apps) report
        // these; Force won't help, so we don't suggest it.
        if joined.contains("no available cask")
            || joined.contains("no cask")
            || joined.contains("it is not")
            || joined.contains("cannot be adopted")
            || joined.contains("not be adopted")
            || joined.contains("permission denied")
            || joined.contains("not allowed")
            || joined.contains("sha256 mismatch")
            || joined.contains("checksum") {
            return .failure("App cannot be Adopted — see conditions above")
        }
        // Version mismatch / already-installed: Force can reinstall over it.
        if joined.contains("version mismatch")
            || joined.contains("already installed")
            || joined.contains("not updated")
            || joined.contains("different version") {
            return .mismatch("Version mismatch — try Force to reinstall over it")
        }
        if joined.contains("was successfully installed") || joined.contains("successfully installed") {
            return .success("Adopted successfully")
        }
        // Any remaining error signal is a generic failure.
        if joined.contains("error") || joined.contains("failed") || joined.contains("abort") {
            return .failure("App cannot be Adopted — see conditions above")
        }
        return .unknown("Adopt finished — re-scan to confirm")
    }

    func loadForgedBrewCacheSize() async {
        forgedbrewCacheSize = await ForgedBrewCacheService.shared.totalCacheSizeString()
    }

    func clearForgedBrewCache() async {
        _ = await ForgedBrewCacheService.shared.clearAll()
        await loadForgedBrewCacheSize()
    }

    // MARK: - Scan result persistence
    //
    // Security & Trust scans are slow (many large bundles). Persist the last
    // completed report to Application Support so reopening a screen — or
    // relaunching the app — shows the saved results immediately with their
    // timestamp, instead of re-running. Auto-re-run only happens once a result
    // is older than `scanFreshness`, or when the user taps Re-scan.

    // Application Support/ForgedBrew/ScanCache, created on demand. Falls back to
    // the temp dir if Application Support is somehow unavailable so persistence
    // never throws (a lost temp cache just means the next open re-scans).
    private static var scanCacheDir: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("ForgedBrew/ScanCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var securityCacheURL: URL { scanCacheDir.appendingPathComponent("security-scan.json") }
    private static var trustCacheURL: URL    { scanCacheDir.appendingPathComponent("trust-scan.json") }

    // Writes the current security report to disk (atomically). Called at the end
    // of every completed security scan. All failures are swallowed — a missed
    // save just costs a re-scan next time, never a crash.
    func saveSecurityScan() {
        // Never persist an empty report: it carries no per-app results and would
        // reload as a misleading "All 0 apps passed" (the "no casks" error text
        // isn't part of the report). Only a real, non-empty completion is cached.
        guard !securityResults.isEmpty else { return }
        let report = SecurityScanReport(results: securityResults, scannedAt: securityScannedAt)
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: Self.securityCacheURL, options: .atomic)
        }
    }
    // Writes the current Gatekeeper-risk result to disk (atomically) at the end
    // of a completed trust scan. The result struct carries its own timestamp.
    func saveTrustScan() {
        if let data = try? JSONEncoder().encode(gatekeeperRiskResult) {
            try? data.write(to: Self.trustCacheURL, options: .atomic)
        }
    }

    // Loads any persisted scan reports back into memory. Called once from `init`,
    // so a freshly-launched screen shows the last results immediately. The
    // `scannedAt != .distantPast` guard rejects a sentinel/empty report (the
    // default timestamp) so we don't pretend a never-run scan has completed —
    // that would leave `hasScanned` true with no real results.
    private func loadPersistedScans() {
        if let data = try? Data(contentsOf: Self.securityCacheURL),
           let report = try? JSONDecoder().decode(SecurityScanReport.self, from: data),
           report.scannedAt != .distantPast {
            securityResults = report.results
            securityScannedAt = report.scannedAt
            securityHasScanned = true
        }
        if let data = try? Data(contentsOf: Self.trustCacheURL),
           let result = try? JSONDecoder().decode(GatekeeperRiskScanResult.self, from: data),
           result.scannedAt != .distantPast {
            gatekeeperRiskResult = result
            trustHasScanned = true
        }
    }

    // Rehydrate persisted Security/Trust reports up front so the screen opens
    // with saved results rather than a blank "never scanned" state.
    init() {
        loadPersistedScans()
    }
}

/// The Maintenance tab's root view. Owns the shared `MaintenanceMetrics`, kicks
/// off the best-effort metric probes in `.task` on appear, lays out the health
/// panel + diagnostics + the action-card grid, and hosts every maintenance sheet
/// (each bound to the shared metrics object).
