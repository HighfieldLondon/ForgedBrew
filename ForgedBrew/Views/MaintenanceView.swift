//
//  MaintenanceView.swift
//  ForgedBrew
//
//  The "Maintenance" tab — the SwiftUI surface for keeping a Homebrew install
//  healthy. The body is a grid of one-tap "action cards"; heavier tasks open a
//  dedicated sheet (Quarantine, Adopt, Duplicates, Orphans, Disk Usage,
//  Security, Vulnerability, Trust), each bound to a shared MaintenanceMetrics.
//
//  This file is just the view. The rest lives alongside it:
//    • MaintenanceMetrics.swift — the @Observable view-model + all scan state
//    • MaintenanceSheets.swift  — QuarantineSheet, AdoptSheet, AdoptRow
//    • MaintenanceCards.swift   — HealthRing, ActionCard
//

import SwiftUI
import AppKit

struct MaintenanceView: View {
    @Environment(AppDataService.self) var appData
    @State private var metrics = MaintenanceMetrics()

    // The 0–100 health score driving the ring. Deliberately simple: start at 100
    // and dock 5 points per outdated package, capped at a 50-point total penalty
    // so the score never drops below 50 from outdated packages alone (the ring
    // stays in the "needs attention", not "critical", zone for updates only).
    private var healthScore: Int {
        let outdatedPenalty = min(appData.installedPackages.filter(\.isOutdated).count * 5, 50)
        return max(0, 100 - outdatedPenalty)
    }

    private var healthMessage: String {
        if healthScore > 80 { return "Your setup looks healthy" }
        else if healthScore > 50 { return "A few updates available" }
        else { return "Maintenance needed" }
    }

    @State private var showBrewfileSheet = false
    @State private var showQuarantineSheet = false
    // Drives the Adopt sheet via .sheet(item:) for race-free presentation.
    // Replaces the old presentation boolean, whose latched true state
    // could leave the sheet unable to re-present until an app restart.
    @State private var showDuplicatesSheet = false
    @State private var showOrphansSheet = false
    @State private var showDiskUsageSheet = false
    @State private var showSecurityScanSheet = false
    @State private var showVulnerabilitySheet = false
    @State private var showTrustMaintenanceSheet = false
    // True while an inline "Run brew cleanup" fix (triggered from a Diagnostics
    // card whose remedy is `brew cleanup`, e.g. broken symlinks) is running.
    // Disables the button and shows a spinner until cleanup + the follow-up
    // brew-doctor re-run finish.
    @State private var cleanupFixRunning = false

    private var outdatedCount: Int { appData.installedPackages.filter(\.isOutdated).count }

    // Tokens Homebrew already manages — used to exclude already-adopted apps
    // from the Adopt scan.
    private var managedTokens: Set<String> {
        Set(appData.installedPackages.filter { $0.type == .cask }.map(\.token))
    }

    // Installed token sets split by type, used by duplicate detection.
    private var installedCaskTokens: Set<String> {
        Set(appData.installedPackages.filter { $0.type == .cask }.map(\.token))
    }
    private var installedFormulaTokens: Set<String> {
        Set(appData.installedPackages.filter { $0.type == .formula }.map(\.token))
    }

    // Summed size of cask-installed app bundles in /Applications. These live
    // outside the Homebrew prefix, so the Disk Usage measurement can't find them
    // via brew's path queries; we reuse the per-cask sizes AppDataService
    // already computed (InstalledPackage.sizeBytes) and pass the total in.
    private var caskAppsBytes: Int64 {
        appData.installedPackages
            .filter { $0.type == .cask }
            .compactMap { $0.sizeBytes }
            .reduce(Int64(0)) { $0 + Int64($1) }
    }

    var body: some View {
        // Bindable view of the shared service so the Adopt sheet can be presented
        // with .sheet(item: $appData.adoptNavigationRequest): the request is the
        // single source of truth, and dismissing the sheet clears it automatically.
        @Bindable var appData = appData
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Title
                VStack(alignment: .leading, spacing: 4) {
                    PageTitleLabel(title: "Maintenance")
                    Text("Keep your Homebrew installation healthy")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                // Full Disk Access status banner
                FullDiskAccessBanner(granted: metrics.fdaGranted)
                    .padding(.horizontal, 20)

                // Homebrew self-update status banner
                HomebrewStatusBanner(metrics: metrics, cli: appData.cli)
                    .padding(.horizontal, 20)

                // Health Score Panel
                HStack(alignment: .center, spacing: 24) {
                    HealthRing(score: healthScore)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(healthMessage)
                            .font(.title3)
                            .fontWeight(.semibold)

                        VStack(alignment: .leading, spacing: 6) {
                            healthCheckItem(
                                text: outdatedCount == 0 ? "All packages up to date" : "\(outdatedCount) packages need updates",
                                ok: outdatedCount == 0
                            )
                            healthCheckItem(
                                text: doctorSummaryText,
                                ok: metrics.doctorReport?.isClean ?? true
                            )
                            healthCheckItem(
                                text: metrics.brewCacheSize.map { "Homebrew cache: \($0)" } ?? "Homebrew cache: measuring…",
                                ok: true
                            )
                        }
                    }

                    Spacer()
                }
                .padding(20)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
                .padding(.horizontal, 20)

                // Brew doctor — itemized findings
                doctorSection

                // Two-column action layout: general upkeep on the left,
                // security checks on the right. Cards are full-width rows within
                // each column and fill it via their own maxWidth: .infinity, so
                // we don't stack competing fixed widths (avoids the AppKit
                // layout recursion this app is careful about — no GeometryReader).
                VStack(spacing: 12) {
                    // Group headers sit above their respective columns so the
                    // grid reads as Maintenance (left) | Security (right).
                    HStack(alignment: .center, spacing: 16) {
                        actionGroupHeader(
                            title: "Maintenance",
                            systemImage: "wrench.and.screwdriver",
                            tint: Color(red: 0.20, green: 0.45, blue: 0.72)
                        )
                        actionGroupHeader(
                            title: "Security",
                            systemImage: "shield.lefthalf.filled",
                            tint: Color(red: 0.22, green: 0.55, blue: 0.34)
                        )
                    }

                    // Render the cards ROW BY ROW (instead of column by column)
                    // and stretch each pair to equal height so the two columns
                    // line up as a uniform grid. Each card already fills its
                    // column width; .frame(maxHeight: .infinity) makes the
                    // shorter card in a row grow to match the taller one.
                    gridRow(diskUsageCard, securityScanCard)
                    gridRow(adoptCard, vulnerabilityScanCard)
                    gridRow(orphansCard, quarantineCard)
                    gridRow(duplicatesCard, trustMaintenanceCard)
                }
                .padding(.horizontal, 20)

                // Cache row: ForgedBrew's own media cache on the left, Homebrew's
                // download cache on the right — two cards, one row.
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "externaldrive")
                            .foregroundStyle(Color(red: 0.20, green: 0.55, blue: 0.58))
                        Text("Cache")
                    }
                    .font(.title3)
                    .fontWeight(.bold)
                    HStack(alignment: .top, spacing: 16) {
                        forgedbrewCacheCard
                        homebrewCacheCard
                    }
                }
                .padding(.horizontal, 20)

                // Backup & Restore row: export the current setup to a Brewfile or
                // reinstall everything from one. (Moved here from the sidebar to
                // keep the sidebar focused on Installed/Updates.)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Color(red: 0.52, green: 0.40, blue: 0.72))
                        Text("Backup & Restore")
                    }
                    .font(.title3)
                    .fontWeight(.bold)
                    brewfileCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        // NOTE: every sheet below re-applies .progressViewStyle(.forgedbrew).
        // Sheets are presented in their own hosting context and do NOT reliably
        // inherit the style set at the WindowGroup root, so without this a bare
        // ProgressView() falls back to the AppKit NSProgressIndicator, which
        // "ghosts" a grey spinner at the sheet's top-center during re-layout
        // (most visible as a scan streams results in). The standalone scan
        // sheets also set it on their own body; the inline sheets (Brewfile,
        // Quarantine, Adopt) get it here. See ForgedBrewSpinner for the why.
        .sheet(isPresented: $showBrewfileSheet) {
            BrewfileView(onDone: { showBrewfileSheet = false })
                .frame(minWidth: 560, minHeight: 520)
                .progressViewStyle(.forgedbrew)
        }
        .sheet(isPresented: $showQuarantineSheet) {
            QuarantineSheet(metrics: metrics, cli: appData.cli)
                .frame(minWidth: 520, minHeight: 420)
                .progressViewStyle(.forgedbrew)
        }
        .sheet(item: $appData.adoptNavigationRequest) { _ in
            // The navigation request is the single source of truth: .sheet(item:)
            // presents whenever it is non-nil and clears it on dismiss, so the
            // Adopt sheet can never be missed by an observer that wasn't mounted
            // yet and is never left latched after a dismissal. AdoptSheet sets its
            // own fixed 600x540 frame internally and runs the candidate scan in
            // its own .task, so presentation no longer depends on mount/observer
            // ordering or a separately-toggled flag.
            AdoptSheet(metrics: metrics, casks: appData.casks, managedTokens: managedTokens, appData: appData)
                .progressViewStyle(.forgedbrew)
        }
        .sheet(isPresented: $showDuplicatesSheet) {
            DuplicatesSheet(metrics: metrics,
                            casks: appData.casks,
                            installedCaskTokens: installedCaskTokens,
                            installedFormulaTokens: installedFormulaTokens,
                            cli: appData.cli)
        }
        .sheet(isPresented: $showOrphansSheet) {
            // OrphansSheet sets its own fixed frame internally.
            OrphansSheet(metrics: metrics, cli: appData.cli)
        }
        .sheet(isPresented: $showDiskUsageSheet) {
            // DiskUsageSheet sets its own fixed frame internally.
            DiskUsageSheet(metrics: metrics, cli: appData.cli, caskAppsBytes: caskAppsBytes)
        }
        .sheet(isPresented: $showSecurityScanSheet) {
            // SecurityScanSheet sets its own fixed frame internally.
            SecurityScanSheet(metrics: metrics, cli: appData.cli)
        }
        .sheet(isPresented: $showVulnerabilitySheet) {
            // VulnerabilityScanSheet sets its own fixed frame internally.
            VulnerabilityScanSheet(metrics: metrics, cli: appData.cli)
        }
        .sheet(isPresented: $showTrustMaintenanceSheet) {
            // TrustMaintenanceSheet sets its own fixed frame internally.
            TrustMaintenanceSheet(metrics: metrics, cli: appData.cli)
        }
        .task {
            // Kick off the best-effort metric probes when the screen appears.
            await metrics.loadFDAStatus()
            await metrics.loadHomebrewStatus(cli: appData.cli)
            await metrics.loadCacheSize(cli: appData.cli)
            await metrics.loadForgedBrewCacheSize()
            await metrics.loadDoctor(cli: appData.cli)
            metrics.loadHiddenAdoptTokens()
        }
    }

    // MARK: - Action column

    // A small tinted group header (Maintenance or Security) that sits above
    // its column. Wrapped in maxWidth: .infinity so the two headers split the
    // row evenly and align with the two card columns below them.
    @ViewBuilder
    private func actionGroupHeader(
        title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 15, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // One row of the Maintenance/Security grid: a left card and a right card.
    // Both are stretched to fill the column width AND to the row\u2019s tallest
    // height (maxHeight: .infinity), so the two columns line up uniformly even
    // when one card has more content than the other. Top alignment keeps each
    // card\u2019s header pinned to the top while the shorter card\u2019s body simply
    // has extra trailing space. No GeometryReader \u2014 pure stack layout.
    @ViewBuilder
    private func gridRow<Left: View, Right: View>(
        _ left: Left,
        _ right: Right
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            left
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            right
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Homebrew Cache card

    // Cache Cleanup, pulled out of the old grid so it can sit beside the ForgedBrew
    // cache card in the Cache row. Runs `brew cleanup --prune=all -s`, which
    // removes old versions and every cached download. It never touches the
    // Caskroom installers Homebrew keeps for installed casks.
    private var homebrewCacheCard: some View {
        ActionCard(
            icon: "trash",
            iconColor: .orange,
            title: "Homebrew Cache",
            description: cacheCleanupDescription,
            onRun: {
                await metrics.loadCacheSize(cli: appData.cli)
                let stream = await appData.cli.deepCleanup()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await metrics.refreshCacheAfterCleanup(cli: appData.cli)
                }
                return stream
            },
            resultSummary: { Self.cleanupSummary($0) },
            primaryTitle: "Clean Up",
            note: "ForgedBrew automatically cleans the cache after every install and update. "
                + "If another app or the command line was used to install or update something, "
                + "use this button to clean up any leftover cache files."
        )
    }

    // MARK: - Remove Quarantine card

    @ViewBuilder
    private var quarantineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "lock.open")
                        .foregroundStyle(.green)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove Quarantine from Applications")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Clear the Gatekeeper flag on downloaded apps")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showQuarantineSheet = true
                    Task { await metrics.loadQuarantinedItems(cli: appData.cli) }
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Security Scan card

    // Short status line shown under the card title: either a call to action, a
    // running indicator, or a one-line summary of the last scan's verdict.
    private var securityScanStatusText: String {
        if metrics.securityScanning { return "Scanning installed apps…" }
        if let err = metrics.securityError, metrics.securityHasScanned { return err }
        if metrics.securityHasScanned {
            let r = metrics.securityReport
            if r.failedCount > 0 {
                return "\(r.failedCount) of \(r.totalCount) need attention"
            } else if r.warnCount > 0 {
                return "\(r.passedCount) passed, \(r.warnCount) with warnings"
            } else {
                return "All \(r.totalCount) apps passed"
            }
        }
        return "Verify signatures, notarization & Gatekeeper"
    }

    @ViewBuilder
    private var securityScanCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.blue)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Security Scan")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(securityScanStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showSecurityScanSheet = true
                } label: {
                    Text("Scan")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Trust Management Screening card

    // Short status line under the card title: a call to action, a running
    // indicator, or a one-line summary of the last scan.
    private var trustMaintenanceStatusText: String {
        if metrics.trustScanning { return "Checking apps against Gatekeeper…" }
        if metrics.trustHasScanned {
            let count = metrics.gatekeeperRiskResult.count
            if count > 0 {
                let app = count == 1 ? "app" : "apps"
                return "\(count) \(app) will break after Sept 1, 2026"
            } else {
                return "All apps will keep working"
            }
        }
        return "Check which apps may fail to launch after Sept 1, 2026"
    }

    @ViewBuilder
    private var trustMaintenanceCard: some View {
        // Tint orange when there are at-risk apps to draw the eye; neutral blue
        // otherwise. We only know there is risk once a scan has run.
        let hasRisk = metrics.trustHasScanned && metrics.gatekeeperRiskResult.count > 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill((hasRisk ? Color.orange : Color.blue).opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: hasRisk ? "exclamationmark.shield" : "checkmark.shield")
                        .foregroundStyle(hasRisk ? .orange : .blue)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trust Management Screening")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(trustMaintenanceStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showTrustMaintenanceSheet = true
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Vulnerability scan card

    private var vulnerabilityScanStatusText: String {
        if metrics.vulnScanning { return "Checking packages against OSV.dev…" }
        if let err = metrics.vulnError, metrics.vulnHasScanned { return err }
        if metrics.vulnHasScanned {
            let r = metrics.vulnReport
            if r.vulnerableCount > 0 {
                let pkg = r.vulnerableCount == 1 ? "package" : "packages"
                return "\(r.vulnerableCount) \(pkg) with known CVEs"
            } else {
                return "No known vulnerabilities found"
            }
        }
        return "Check installed packages for known CVEs"
    }

    private var vulnerabilityScanCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "ladybug")
                        .foregroundStyle(.orange)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vulnerability Scan")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(vulnerabilityScanStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showVulnerabilitySheet = true
                } label: {
                    Text("Scan")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Adopt Apps card

    @ViewBuilder
    private var adoptCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adopt Apps into Homebrew")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Let Homebrew manage apps you already installed manually")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    // Drive the same request the row Adopt buttons use, so this
                    // entry point presents the sheet through the one mechanism.
                    // The sheet runs the candidate scan in its own .task.
                    appData.adoptNavigationRequest = AdoptNavigationRequest(
                        bundleID: "",
                        appName: "",
                        suggestedToken: nil
                    )
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Orphaned Packages card

    @ViewBuilder
    private var orphansCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "leaf")
                        .foregroundStyle(.orange)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean Up Orphaned Packages")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Remove formulae kept only as now-unneeded dependencies")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showOrphansSheet = true
                    Task { await metrics.loadOrphans(cli: appData.cli) }
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Disk Usage card

    @ViewBuilder
    private var diskUsageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.teal)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Disk Usage")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("See how much space Homebrew uses, broken down by location")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showDiskUsageSheet = true
                    Task { await metrics.loadDiskFootprint(cli: appData.cli, caskAppsBytes: caskAppsBytes) }
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Duplicates card

    @ViewBuilder
    private var duplicatesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.purple.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.purple)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find Duplicate Installs")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Spot apps installed more than once and remove the extra copy")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showDuplicatesSheet = true
                    Task {
                        await metrics.loadDuplicates(
                            casks: appData.casks,
                            installedCaskTokens: installedCaskTokens,
                            installedFormulaTokens: installedFormulaTokens,
                            cli: appData.cli
                        )
                    }
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Derived text

    private var doctorSummaryText: String {
        if metrics.doctorLoading { return "Running brew doctor…" }
        guard let report = metrics.doctorReport else { return "brew doctor status pending" }
        if report.isClean { return "brew doctor: system ready" }
        // Name the actual issue(s) so the user knows what to look at in the
        // Diagnostics list below, rather than just a bare count. We pull a short
        // label off each finding (e.g. "Untrusted taps", "Broken symlinks") and
        // join them. If the list gets long we show the first couple plus a
        // "+N more" so the health panel line stays readable.
        let labels = report.findings.map { Self.doctorIssueLabel(for: $0) }
        let n = labels.count
        let prefix = "brew doctor: \(n) issue\(n == 1 ? "" : "s") — "
        if labels.count <= 2 {
            return prefix + labels.joined(separator: ", ")
        }
        let shown = labels.prefix(2).joined(separator: ", ")
        return prefix + "\(shown) +\(labels.count - 2) more"
    }

    // Turns one brew-doctor finding into a short, plain-language label for the
    // health-panel summary line. The untrusted-taps finding gets a friendly
    // name (and a count when it covers multiple taps); everything else is
    // derived by tidying the raw warning title brew prints.
    static func doctorIssueLabel(for finding: BrewCLIService.DoctorFinding) -> String {
        if !finding.untrustedTaps.isEmpty {
            let c = finding.untrustedTaps.count
            return c == 1 ? "Untrusted tap" : "\(c) untrusted taps"
        }
        let base = shortIssueLabel(from: finding.title)
        return finding.occurrences > 1 ? "\(base) (×\(finding.occurrences))" : base
    }

    // brew doctor titles look like "Warning: Some installed formulae are
    // deprecated." — strip the "Warning:" prefix and trailing punctuation, then
    // map a few common ones to crisp labels. Falls back to a trimmed version of
    // brew's own wording so unknown warnings still read sensibly.
    static func shortIssueLabel(from title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "warning:", options: .caseInsensitive) {
            t = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        while let last = t.last, ".!:".contains(last) { t.removeLast() }
        let lower = t.lowercased()
        if lower.contains("not trusted") || lower.contains("untrusted tap") { return "Untrusted taps" }
        if lower.contains("broken symlink") { return "Broken symlinks" }
        if lower.contains("unbrewed") && lower.contains("dylib") { return "Unbrewed dylibs" }
        if lower.contains("unbrewed") && lower.contains("header") { return "Unbrewed headers" }
        if lower.contains("unbrewed") { return "Unbrewed files" }
        // Distinguish a deprecated *syntax* warning (brew complaining that a
        // tap's formula/cask Ruby file uses an old DSL call like
        // `depends_on macos:` string comparison) from genuinely deprecated
        // *packages*. The former is a tap-maintainer issue, not something the
        // user installed, so calling it "Deprecated formulae" is misleading.
        if lower.contains("deprecated") {
            if lower.contains("depends_on") || lower.contains("string comparison")
                || lower.contains("calling") || lower.contains("syntax")
                || lower.contains("dsl") {
                return "Deprecated cask syntax"
            }
            return "Deprecated formulae"
        }
        if lower.contains("outdated") { return "Outdated packages" }
        if lower.contains("not on your path") || lower.contains("not in your path") { return "PATH not configured" }
        if lower.contains("out of date") { return "Homebrew out of date" }
        if lower.contains("cellar") { return "Cellar issue" }
        // Unknown warning: keep brew's first words so it still means something.
        let words = t.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? "Unknown issue" : words
    }

    private var cacheCleanupDescription: String {
        if let after = metrics.brewCacheSizeAfter, let before = metrics.brewCacheSize {
            return "Cache was \(before), now \(after)"
        }
        if let before = metrics.brewCacheSize {
            return "Cache is \(before) — clean up old versions and cached downloads"
        }
        return "Remove old versions and cached downloads to free up space"
    }

    // MARK: - Friendly result summaries (parse brew output into one clean line)

    // Doctor: brew prints "Your system is ready to brew." when clean, otherwise
    // one or more "Warning:" blocks. We surface a reassuring "Ready to brew" or,
    // when there are warnings, NAME them (e.g. "Untrusted taps, Broken symlinks")
    // so the user knows what to look at in Diagnostics below — not just a count.
    static func doctorSummary(_ lines: [String]) -> String {
        let joined = lines.joined(separator: "\n").lowercased()
        if joined.contains("ready to brew") { return "Ready to brew" }
        // Each warning starts with a "Warning:" line; turn those titles into
        // short labels, de-duplicating so repeated kinds don't pile up.
        var labels: [String] = []
        for line in lines where line.lowercased().hasPrefix("warning:") {
            let label = shortIssueLabel(from: line)
            if !labels.contains(label) { labels.append(label) }
        }
        if labels.isEmpty {
            // No explicit "ready" line and no warnings parsed: treat as healthy.
            return "Ready to brew"
        }
        let n = labels.count
        let prefix = "\(n) issue\(n == 1 ? "" : "s") found — "
        if labels.count <= 2 {
            return prefix + labels.joined(separator: ", ") + " (see Diagnostics)"
        }
        let shown = labels.prefix(2).joined(separator: ", ")
        return prefix + "\(shown) +\(labels.count - 2) more (see Diagnostics)"
    }

    // Cache cleanup: brew prints a trailing line like
    // "==> This operation has freed approximately 1.2GB of disk space."
    // Surface that figure; otherwise report a tidy generic result.
    static func cleanupSummary(_ lines: [String]) -> String {
        for line in lines {
            let l = line.lowercased()
            if l.contains("freed"), let range = l.range(of: "approximately") {
                // Pull the size token after "approximately".
                let after = String(l[range.upperBound...])
                    .replacingOccurrences(of: "of disk space.", with: "")
                    .replacingOccurrences(of: "of disk space", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty { return "Freed approximately \(after.uppercased())" }
            }
        }
        // brew prints nothing meaningful when the cache is already empty.
        let didRemove = lines.contains { $0.lowercased().hasPrefix("removing") || $0.lowercased().contains("pruned") }
        return didRemove ? "Cache cleaned" : "Cache already clean — nothing to remove"
    }

    // Auto Remove: brew lists "Removing: <formula>..." / "Uninstalling" lines, or
    // prints nothing when there are no orphaned dependencies.
    static func autoremoveSummary(_ lines: [String]) -> String {
        let removed = lines.filter {
            let l = $0.lowercased()
            return l.hasPrefix("removing") || l.hasPrefix("uninstalling")
        }.count
        if removed > 0 {
            return "Removed \(removed) unused package\(removed == 1 ? "" : "s")"
        }
        return "Nothing to remove — no unused dependencies"
    }

    // MARK: - Doctor section

    @ViewBuilder
    private var doctorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Diagnostics")
                    .font(.title3)
                    .fontWeight(.bold)
                // Re-run sits just to the right of the section title.
                PageRefreshButton("Re-run", isWorking: metrics.doctorLoading, size: .compact) {
                    Task { await metrics.loadDoctor(cli: appData.cli) }
                }
                Spacer()
            }
            // A one-line, plain-language recap that NAMES the issues brew doctor
            // found, so the user knows exactly what the cards below are about
            // instead of scanning a long page. Hidden while loading or clean.
            if !metrics.doctorLoading,
               let report = metrics.doctorReport,
               !report.isClean {
                let labels = report.findings.map { Self.doctorIssueLabel(for: $0) }
                let n = labels.count
                Text("^[\(n) issue](inflect: true) to review: \(labels.joined(separator: ", "))")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if metrics.doctorLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Running brew doctor…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
            } else if let report = metrics.doctorReport {
                if report.isClean {
                    doctorRow(
                        icon: "checkmark.seal.fill",
                        iconColor: .green,
                        title: "Your system is ready to brew",
                        detail: "No issues found by brew doctor."
                    )
                } else {
                    // Three-tier severity:
                    //  • brew said "ready to brew" -> the findings are non-fatal
                    //    WARNINGS: yellow caution icon, plus a green "ready"
                    //    confirmation row beneath them.
                    //  • brew did NOT say "ready" -> the findings are FATAL
                    //    errors that actually block Homebrew: red error icon,
                    //    and no green confirmation.
                    let isFatal = !report.systemReady
                    let icon = isFatal ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                    let tint: Color = isFatal ? .red : .yellow
                    VStack(spacing: 8) {
                        ForEach(report.findings) { finding in
                            if !finding.untrustedTaps.isEmpty {
                                untrustedTapsFinding(finding)
                            } else if Self.isCleanupFixable(finding) {
                                cleanupFixableRow(finding, tint: tint, icon: icon)
                            } else {
                                doctorRow(
                                    icon: icon,
                                    iconColor: tint,
                                    title: finding.occurrences > 1
                                        ? "\(finding.title)  (×\(finding.occurrences))"
                                        : finding.title,
                                    detail: finding.detail
                                )
                            }
                        }
                        // brew said the system is "ready to brew" even though it
                        // also printed the warning(s) above — they are non-fatal.
                        // Mirror brew by reassuring the user the system still
                        // works, in green beneath the warnings.
                        if report.systemReady {
                            doctorRow(
                                icon: "checkmark.seal.fill",
                                iconColor: .green,
                                title: "Your system is ready to brew",
                                detail: "The warning(s) above are non-fatal — Homebrew still works normally."
                            )
                        }
                    }
                }
            }
        }
    }
    // A brew-doctor finding is "cleanup-fixable" when brew itself tells the user
    // the remedy is `brew cleanup` (the classic case being broken symlinks like
    // /opt/homebrew/opt/python@3). We look in both the title and the detail so
    // we catch it regardless of which line carried the instruction.
    static func isCleanupFixable(_ finding: BrewCLIService.DoctorFinding) -> Bool {
        let haystack = (finding.title + " " + finding.detail).lowercased()
        return haystack.contains("brew cleanup")
    }

    // Runs `brew cleanup`, then re-runs brew doctor so the fixed finding clears
    // from the Diagnostics list on success.
    private func runInlineCleanup() {
        guard !cleanupFixRunning else { return }
        cleanupFixRunning = true
        Task {
            // Drain the cleanup stream to completion (we don't need the chatty
            // per-file log here — just to wait until brew is finished).
            let stream = await appData.cli.normalCleanup()
            for await _ in stream { }
            // Re-probe so the resolved finding disappears.
            await metrics.loadDoctor(cli: appData.cli)
            cleanupFixRunning = false
        }
    }

    // Like doctorRow, but with an inline "Run brew cleanup" fix button on the
    // right. Used for findings whose remedy is `brew cleanup` so the fix is one
    // click from the problem.
    private func cleanupFixableRow(_ finding: BrewCLIService.DoctorFinding,
                                   tint: Color = .yellow,
                                   icon: String = "exclamationmark.triangle.fill") -> some View {
        let title = finding.occurrences > 1
            ? "\(finding.title)  (×\(finding.occurrences))"
            : finding.title
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                if !finding.detail.isEmpty {
                    Text(finding.detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(action: runInlineCleanup) {
                HStack(spacing: 6) {
                    if cleanupFixRunning {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(cleanupFixRunning ? "Cleaning…" : "Run brew cleanup")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(cleanupFixRunning)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func doctorRow(icon: String, iconColor: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }
    // MARK: - Untrusted taps (two-box layout)
    //
    // The user asked for a clean split: a top box listing each not-trusted tap
    // with what we know about it (when added, last updated, what it provides),
    // then a separate, shorter box that explains the Homebrew trust change in
    // plain language — not the full wall of brew command examples that brew
    // doctor prints, just the gist of what is happening and why.
    @ViewBuilder
    private func untrustedTapsFinding(_ finding: BrewCLIService.DoctorFinding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Box 1 — the apps/taps that are not trusted.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                    Text(finding.title)
                    Spacer(minLength: 0)
                }
                ForEach(finding.untrustedTaps) { tap in
                    untrustedTapCard(tap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
            // Box 2 — the concise explanation of the trust change.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                    Text("What this means")
                }
                Text(finding.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        }
    }
    // One not-trusted tap as a compact card: name, a row of stat chips
    // (provides / added / updated), and any sample contents. Everything we
    // couldn't read off disk is simply omitted.
    @ViewBuilder
    private func untrustedTapCard(_ tap: BrewCLIService.UntrustedTap) -> some View {
        let busy = metrics.tapActionInFlight.contains(tap.name)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tap.name)
                    HStack(spacing: 6) {
                        tapStat("shippingbox", Self.tapProvidesText(tap))
                        if let added = tap.tappedDate {
                            tapStat("calendar.badge.plus", "Added \(Self.shortDate(added))")
                        }
                        if let updated = tap.lastUpdated {
                            tapStat("clock.arrow.circlepath", "Updated \(Self.shortDate(updated))")
                        }
                    }
                    if !tap.sampleNames.isEmpty {
                        Text("Includes: \(tap.sampleNames.joined(separator: ", "))")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                // Actions: Trust keeps the tap so Homebrew keeps loading and
                // updating it; Remove Tap deletes the tap's install recipes
                // (not your installed apps) after a confirmation. A spinner
                // replaces both while a brew action for this tap is in flight.
                if busy {
                    ProgressView().scaleEffect(0.6).frame(width: 60)
                } else {
                    HStack(spacing: 6) {
                        Button {
                            Task { await metrics.trustTap(tap.name, cli: appData.cli) }
                        } label: {
                            Text("Trust")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                        .help("Tell Homebrew to keep loading and updating this tap (runs “brew trust”). Your installed apps keep getting updates.")
                        Button {
                            metrics.tapPendingUntap = tap.name
                        } label: {
                            Text("Remove Tap")
                        }
                        .buttonStyle(OutlinedButtonStyle())
                        .controlSize(.small)
                        .help("Remove this tap’s install recipes (runs “brew untap”). Your installed apps stay and keep running, but Homebrew stops tracking and updating them. Blocked if packages are still installed from it.")
                    }
                }
            }
            if let error = metrics.tapActionErrors[tap.name], !error.isEmpty {
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            "Remove the tap “\(tap.name)”?",
            isPresented: Binding(
                get: { metrics.tapPendingUntap == tap.name },
                set: { if !$0 { metrics.tapPendingUntap = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Tap", role: .destructive) {
                metrics.tapPendingUntap = nil
                Task { await metrics.untapTap(tap.name, cli: appData.cli) }
            }
            Button("Cancel", role: .cancel) {
                metrics.tapPendingUntap = nil
            }
        } message: {
            Text("This deletes the tap’s install recipes (runs “brew untap \(tap.name)”). Apps you already installed from it stay on your Mac and keep running — but Homebrew will no longer update or track them. To manage them again later, re-add the tap with “brew tap \(tap.name)”. Homebrew will refuse if packages are still installed from this tap.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5))
    }
    private func tapStat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .background(Color.secondary.opacity(0.1), in: Capsule())
    }
    // "3 casks", "1 cask, 2 formulae", etc. Falls back to a neutral label when
    // we couldn't read the tap's contents off disk.
    private static func tapProvidesText(_ tap: BrewCLIService.UntrustedTap) -> String {
        var parts: [String] = []
        if tap.caskCount > 0 { parts.append("\(tap.caskCount) cask\(tap.caskCount == 1 ? "" : "s")") }
        if tap.formulaCount > 0 { parts.append("\(tap.formulaCount) formula\(tap.formulaCount == 1 ? "" : "e")") }
        return parts.isEmpty ? "No items" : parts.joined(separator: ", ")
    }
    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
    // MARK: - Brewfile card
    // Backup & Restore entry point. Opens the full BrewfileView (export / import)
    // in a sheet. Lives on the Maintenance screen so the sidebar stays focused
    // on Installed and Updates.
    private var brewfileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "doc.text")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brewfile")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Export your setup to a Brewfile or reinstall everything from one")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showBrewfileSheet = true
                } label: {
                    Text("Export / Import…")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - ForgedBrew cache card

    // ForgedBrew's own downloaded-media cache (screenshots + favicons), as a single
    // card so it can sit in the two-up Cache row next to the Homebrew cache.
    private var forgedbrewCacheCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "photo.stack")
                        .foregroundStyle(.teal)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ForgedBrew Cache")
                        .font(.system(size: 13, weight: .semibold))
                    Text(metrics.forgedbrewCacheSize.map { "Screenshots & icons — \($0) on disk" } ?? "Measuring…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    Task { await metrics.clearForgedBrewCache() }
                } label: {
                    Text("Clear Cache")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
            // Explanatory footnote (mirrors the Homebrew Cache card note):
            // reassures the user that clearing this cache is harmless.
            Divider()
            Text("These are the screenshots and app icons ForgedBrew downloads while "
                + "you search and view apps and casks. It is safe to clear them — "
                + "they are re-downloaded automatically the next time they are needed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }
    private func healthCheckItem(text: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(text)
        }
    }
}
