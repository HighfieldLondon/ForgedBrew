//
//  MaintenanceSheets.swift
//  ForgedBrew
//
//  Sheets presented from the Maintenance screen, split out of MaintenanceView
//  for readability: QuarantineSheet (clear the macOS quarantine flag from
//  installed apps) and AdoptSheet + AdoptRow (hand unmanaged apps to Homebrew
//  via `brew install --cask --adopt`). Pure code motion — behaviour unchanged;
//  shared state still lives on MaintenanceMetrics.
//

import SwiftUI
import AppKit

/// Multi-select sheet listing every quarantined app across the folders ForgedBrew
/// scans (/Applications, ~/Applications, and the user's custom app folders).
/// The user can check any subset and remove quarantine, or use
/// the top button to clear quarantine from all listed files at once. Backed by
/// the shared `MaintenanceMetrics` (scan + removal state live there).
struct QuarantineSheet: View {
    @Bindable var metrics: MaintenanceMetrics
    let cli: BrewCLIService
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    private var allSelected: Bool {
        !metrics.quarantinedItems.isEmpty &&
        selection.count == metrics.quarantinedItems.count
    }
    private var busy: Bool { metrics.quarantineScanning || metrics.quarantineRemoving }
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "lock.open")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quarantined Files")
                    // Keep this crisp instead of listing every scanned path — the
                    // custom folders could be several long paths. The actual set is
                    // /Applications + ~/Applications + the user's custom app folders
                    // (Settings), per AppLocationSettings.
                    Text("/Applications, ~/Applications & your custom app folders")
                }
                // Manual re-scan of the quarantine list, just to the right of
                // the title. Disabled while a scan or removal is in flight.
                PageRefreshButton("Re-scan", isWorking: busy, size: .compact, showsSpinner: false) {
                    Task { await metrics.loadQuarantinedItems(cli: cli) }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            // Padding so the title and the Re-scan/Done buttons aren't jammed
            // against the window's top and right edges (Done was getting clipped
            // in the top-right corner).
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider()
            // Top action bar: remove-from-all + select-all toggle
            HStack(spacing: 12) {
                Button {
                    let paths = metrics.quarantinedItems.map(\.path)
                    Task {
                        await metrics.removeQuarantine(paths: paths, cli: cli)
                        selection.removeAll()
                    }
                } label: {
                    Text("Remove quarantine from all files")
                }
                .buttonStyle(PillActionButtonStyle())
                .disabled(busy || metrics.quarantinedItems.isEmpty)

                Spacer()

                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(metrics.quarantinedItems.map(\.path))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(busy || metrics.quarantinedItems.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // List / states
            Group {
                if metrics.quarantineScanning {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning for quarantined files…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if metrics.quarantinedItems.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 30))
                            .foregroundStyle(.green)
                        Text("No quarantined files found")
                            .font(.system(size: 13, weight: .medium))
                        Text("None of your installed apps carry the quarantine flag.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(metrics.quarantinedItems) { item in
                                Button {
                                    toggle(item.path)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selection.contains(item.path) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(selection.contains(item.path) ? Color.accentColor : Color.secondary)
                                            .font(.system(size: 15))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.displayName)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            Text(item.path)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Error row (e.g. a removal that failed — System Integrity Protection / permissions)
            if let err = metrics.quarantineError, !err.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            // Footer: remove-selected
            HStack {
                if metrics.quarantineRemoving {
                    ProgressView().scaleEffect(0.6)
                    Text("Removing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(selection.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    let paths = Array(selection)
                    Task {
                        await metrics.removeQuarantine(paths: paths, cli: cli)
                        selection.removeAll()
                    }
                } label: {
                    Text("Remove Quarantine from Selected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selection.isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(Color.accentColor),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(busy || selection.isEmpty)
            }
            .padding(16)
        }
    }

    private func toggle(_ path: String) {
        if selection.contains(path) {
            selection.remove(path)
        } else {
            selection.insert(path)
        }
    }
}

// MARK: - Adopt Apps sheet

/// Lists apps in /Applications (and ~/Applications) that aren't managed by
/// Homebrew but match a known cask, and lets the user adopt each one
/// (`brew install --cask --adopt`). Mirrors the QuarantineSheet structure:
/// header + re-scan, a scrollable list of rows, and a footer. Per-row actions:
/// Adopt, Force-adopt (after a version-mismatch), Hide, and a manual cask
/// override for when the suggested token is wrong. A "Manage Hidden Apps"
/// disclosure lets the user unhide previously-hidden apps.
struct AdoptSheet: View {
    @Bindable var metrics: MaintenanceMetrics
    let casks: [CaskMetadata]
    let managedTokens: Set<String>
    let appData: AppDataService
    @Environment(\.dismiss) private var dismiss

    // Hidden apps are the user's deliberate "I'll manage this myself" choice, so
    // they stay collapsed by default — the sheet shows only the state the user
    // put each app in, never the adoptable + hidden lists side by side. A small
    // toggle reveals the hidden list when the user actually wants to unhide one.
    @State private var showHidden = false

    private var busy: Bool { metrics.adoptScanning || !metrics.adoptingTokens.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            warningBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // Anchor the sheet to a SINGLE definite width (not a range) so AppKit
        // resolves layout in one top-down pass. A width range still let the
        // multi-line text and Spacer-driven rows re-negotiate width on first
        // layout, which trips _NSDetectedLayoutRecursion when the sheet opens.
        .frame(width: 600, height: 540)
        .task {
            // Scan for adoptable apps as soon as the sheet presents. This used to
            // live in the caller that opened the sheet; centralizing it here means
            // the scan runs exactly once per presentation regardless of which
            // entry point opened the sheet.
            await metrics.loadAdoptCandidates(casks: casks, managedTokens: managedTokens, cli: appData.cli, appData: appData)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Adopt Apps into Homebrew")
                    .font(.system(size: 15, weight: .bold))
                Text("\u{201C}Adopting\u{201D} hands an app you installed manually to Homebrew so you can update and remove it from ForgedBrew \u{2014} without losing your data. Review each match below, then Adopt. If an app can\u{2019}t be adopted in place (for example, a version mismatch), you have two options: in Mac Store/Other Apps, click Uninstall to remove it, then install the Homebrew version by searching for it and installing it from there \u{2014} so Homebrew keeps it updated. Or Hide it and keep managing it yourself.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Re-scan sits just to the right of the title, matching the main pages.
            PageRefreshButton("Re-scan", isWorking: busy, size: .compact, showsSpinner: false) {
                Task {
                    await metrics.loadAdoptCandidates(casks: casks, managedTokens: managedTokens, cli: appData.cli, appData: appData)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Accuracy warning

    private var warningBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text("Always verify the suggested cask is correct before adopting. Detection may not always be accurate.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: Content (states)

    @ViewBuilder
    private var content: some View {
        if metrics.adoptScanning {
            VStack(spacing: 10) {
                ProgressView()
                Text("Scanning your apps…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if metrics.adoptCandidates.isEmpty && metrics.hiddenAdoptTokens.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                Text("Nothing to adopt")
                    .font(.system(size: 13, weight: .medium))
                Text("Every app we recognized is already managed by Homebrew (or hidden).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Section 1 — Adoptable apps.
                    sectionHeader("Adoptable apps", systemImage: "square.and.arrow.down", count: metrics.adoptCandidates.count)
                    if metrics.adoptCandidates.isEmpty {
                        Text("No apps left to adopt — they\u{2019}re already managed by Homebrew or hidden below.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                    }
                    ForEach(metrics.adoptCandidates) { candidate in
                        AdoptRow(
                            candidate: candidate,
                            metrics: metrics,
                            casks: casks,
                            managedTokens: managedTokens,
                            appData: appData
                        )
                        Divider().padding(.leading, 16)
                    }

                    // Section 2 — Hidden apps. Collapsed by default behind a
                    // small toggle so the sheet shows only one list at a time:
                    // the user already chose to manage these, so they stay out
                    // of sight until the user asks to see them (to unhide).
                    if !metrics.hiddenAdoptTokens.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { showHidden.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showHidden ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 11))
                                Text(showHidden
                                        ? "Hide \(metrics.hiddenAdoptTokens.count) hidden app\(metrics.hiddenAdoptTokens.count == 1 ? "" : "s")"
                                        : "Show \(metrics.hiddenAdoptTokens.count) hidden app\(metrics.hiddenAdoptTokens.count == 1 ? "" : "s")")
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                        }
                        .buttonStyle(.plain)

                        if showHidden {
                            Text("You chose to manage these yourself. Unhide one to bring it back into the adoptable list.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 4)
                            hiddenRows
                        }
                    }
                }
            }
        }
    }

    // A section title with an icon and a count pill, used to split the sheet
    // into "Adoptable apps" and "Hidden apps".
    private func sectionHeader(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // The hidden-app rows, each with an Unhide button.
    private var hiddenRows: some View {
        ForEach(Array(metrics.hiddenAdoptTokens).sorted(), id: \.self) { token in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    AppIconView(token: token, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(InstalledRowView.displayName(for: token))
                            .font(.system(size: 12, weight: .medium))
                        Text(token)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        metrics.unhideAdopt(token: token)
                        Task {
                            await metrics.loadAdoptCandidates(casks: casks, managedTokens: managedTokens, cli: appData.cli, appData: appData)
                        }
                    } label: {
                        Label("Unhide", systemImage: "eye")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Bring this app back into the adoptable list")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider().padding(.leading, 16)
            }
        }
    }

    // MARK: Footer (count + adopting status)
    //
    // Hidden-app management now lives in the content area's "Hidden apps"
    // section (with per-app Unhide buttons), so the footer just shows progress
    // and a found-count summary.

    private var footer: some View {
        HStack {
            if !metrics.adoptingTokens.isEmpty {
                ProgressView().scaleEffect(0.6)
                Text("Adopting…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(metrics.adoptCandidates.count) app\(metrics.adoptCandidates.count == 1 ? "" : "s") found")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Adopt row

/// A single adoptable app: icon, name, suggested cask token, and actions.
/// Tapping "Adopt" runs `brew install --cask --adopt`; if that reports a version
/// mismatch a "Force" button appears to reinstall over it. "Change" reveals a
/// manual token override for when the suggestion is wrong, and "Hide" removes the
/// app from the list (persisted). Also runs the "smart" version diagnosis below
/// that flags a likely-wrong adoption (installed newer/older than the cask, or a
/// short-vs-long version-number shape) in red before the user commits.
private struct AdoptRow: View {
    let candidate: BrewCLIService.AdoptCandidate
    @Bindable var metrics: MaintenanceMetrics
    let casks: [CaskMetadata]
    let managedTokens: Set<String>
    let appData: AppDataService

    @State private var editingToken = false
    @State private var overrideText = ""

    // The token we'd actually adopt: the user's override if they typed one,
    // otherwise the suggested token.
    private var effectiveToken: String {
        let trimmed = overrideText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? candidate.suggestedToken : trimmed
    }

    private var isAdopting: Bool { metrics.adoptingTokens.contains(effectiveToken) || metrics.adoptingTokens.contains(candidate.suggestedToken) }

    private var outcome: AdoptOutcome? {
        metrics.adoptResults[effectiveToken] ?? metrics.adoptResults[candidate.suggestedToken]
    }

    // Offer Force only on a version mismatch (where reinstalling over the app
    // helps). Real failures like OneDrive don't get a Force button — it won't
    // help and would just fail again.
    private var showForce: Bool { outcome?.isMismatch ?? false }

    // Which side of the version comparison to flag in red, plus a short reason.
    // Drives the colored version line + warning beneath the app name.
    private enum FlaggedSide { case installed, homebrew }
    private struct VersionDiagnosis {
        var flagged: FlaggedSide?
        var message: String?
    }

    // Splits a version string into its leading integer components. Strips a
    // leading "v", splits on "." / "_" / "-", and reads the leading integer of
    // each piece (so "1.2606.0101" -> [1, 2606, 101], "v2.3-beta" -> [2, 3]).
    // Pieces with no leading digits are dropped so suffixes like "beta" don't
    // derail the numeric compare.
    private func versionComponents(_ raw: String) -> [Int] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let body = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst()) : trimmed
        let pieces = body.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
        var out: [Int] = []
        for piece in pieces {
            let digits = piece.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, let n = Int(digits) else { continue }
            out.append(n)
        }
        return out
    }

    // The raw "." -separated part count, used to detect a short-vs-long version
    // shape (e.g. installed "1.2606" vs homebrew "1.2606.0101").
    private func dotPartCount(_ raw: String) -> Int {
        let body = raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
        return body.split(separator: ".").count
    }

    // Compares two component arrays lexically. Returns .orderedDescending when
    // `a` is newer than `b`, .orderedAscending when older, .orderedSame when the
    // shared leading components all match (ignoring extra trailing parts).
    private func compareComponents(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] < b[i] ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // Smart checks the user asked for, comparing the installed app version with
    // the Homebrew (cask) version we'd adopt to. Two cases get flagged in red:
    //   1. Installed is NEWER than the Homebrew version (e.g. Caffeine): the
    //      lower Homebrew version is highlighted with a "newer on installed" note.
    //   1b. Installed is OLDER than the Homebrew version (e.g. Hidden Bar 1.8 vs
    //      1.10 — dotted/semver, so 1.10 is newer): the installed version is
    //      flagged with a note to install the newer Homebrew build and remove the
    //      old copy. (1.10 > 1.8 because .10 is the 10th minor release, not a decimal.)
    //   2. The two share the same leading numbers but one is a longer dotted
    //      release string (e.g. Copilot installed "1.2606" vs cask "1.2606.0101"):
    //      the longer version is flagged as a possible adoption mismatch.
    // Anything else (homebrew newer, equal, or unparseable) is not flagged.
    private var versionDiagnosis: VersionDiagnosis {
        guard let installedRaw = candidate.installedVersion,
              let homebrewRaw = candidate.latestVersion,
              !installedRaw.isEmpty, !homebrewRaw.isEmpty,
              installedRaw != homebrewRaw else { return VersionDiagnosis() }

        let inst = versionComponents(installedRaw)
        let hb = versionComponents(homebrewRaw)
        guard !inst.isEmpty, !hb.isEmpty else { return VersionDiagnosis() }

        let order = compareComponents(inst, hb)

        // Case 1: installed strictly newer than the Homebrew version.
        if order == .orderedDescending {
            return VersionDiagnosis(flagged: .homebrew,
                                    message: "Version is newer on currently installed.")
        }

        // Case 1b: installed strictly OLDER than the Homebrew version (e.g.
        // Hidden Bar installed 1.8 vs Homebrew 1.10 — 1.10 is the newer release,
        // dotted/semver, NOT a decimal). Rather than adopt the stale build in
        // place, point the user at the newer Homebrew version and the removal
        // paths for the old copy. Flag the lower (installed) version.
        if order == .orderedAscending {
            return VersionDiagnosis(flagged: .installed,
                                    message: "Homebrew has a newer version (\(homebrewRaw)) than the installed \(installedRaw). To manage it through Homebrew, click Uninstall in Mac Store/Other Apps to remove it, then install the Homebrew version by searching for it and installing it there \u{2014} or Hide it and keep managing it yourself.")
        }

        // Case 2: leading numbers match, but one string has extra dotted parts.
        // Flag the LONGER one (and only when there's a real dot-count gap, like
        // "1.2606" vs "1.2606.0101", not just trailing zero differences).
        if order == .orderedSame {
            let instDots = dotPartCount(installedRaw)
            let hbDots = dotPartCount(homebrewRaw)
            if instDots != hbDots {
                let longerIsHomebrew = hbDots > instDots
                return VersionDiagnosis(
                    flagged: longerIsHomebrew ? .homebrew : .installed,
                    message: "Version numbers differ in length — this app may not be adoptable due to versioning.")
            }
        }

        return VersionDiagnosis()
    }

    // The trailing "added <date>" context, when we have an install date.
    private var addedDateText: String? {
        guard let date = candidate.installDate else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return "added \(f.string(from: date))"
    }

    // True when we have any version/date context to render at all.
    private var hasInfoLine: Bool {
        candidate.installedVersion != nil || candidate.latestVersion != nil || candidate.installDate != nil
    }

    // The version context line, rendered as separate colored segments so we can
    // flag a single version in red per `versionDiagnosis`. Styled to match the
    // larger, mid-bold secondary text used on the Installed/Updates screens
    // (size 12, semibold) rather than the old tiny tertiary text.
    @ViewBuilder
    private var infoLineView: some View {
        let diag = versionDiagnosis
        HStack(spacing: 8) {
            if let v = candidate.installedVersion, !v.isEmpty {
                Text("Installed \(v)")
                    .foregroundStyle(diag.flagged == .installed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
            if let latest = candidate.latestVersion, !latest.isEmpty,
               latest != candidate.installedVersion {
                Text("Homebrew \(latest)")
                    .foregroundStyle(diag.flagged == .homebrew ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
            if let added = addedDateText {
                Text(added)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                AppIconView(token: candidate.suggestedToken, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.appName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("cask:")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(effectiveToken)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button {
                            editingToken.toggle()
                        } label: {
                            Text(editingToken ? "Done" : "Change")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    // Version / install-date context so the user can decide.
                    // Now larger + mid-bold (matching the Installed/Updates
                    // screens) and color-flagged when a version looks off.
                    if hasInfoLine {
                        infoLineView
                    }
                    // Smart version warning (installed newer than Homebrew, or a
                    // short-vs-long version-number mismatch). Shown in red just
                    // beneath the version line so the user understands the flag.
                    if let warning = versionDiagnosis.message {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                            Text(warning)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 1)
                    }
                }
                Spacer()

                if isAdopting {
                    ProgressView().scaleEffect(0.6)
                } else {
                    HStack(spacing: 8) {
                        if showForce {
                            adoptButton(title: "Force", force: true, filled: true)
                        }
                        adoptButton(title: "Adopt", force: false, filled: !showForce)
                        Button {
                            metrics.hideAdopt(token: candidate.suggestedToken)
                        } label: {
                            Text("Hide")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if editingToken {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField(candidate.suggestedToken, text: $overrideText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: 220)
                    Text("The suggested cask may be wrong — enter the correct one.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.leading, 44)
            }

            if let outcome {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: outcomeIcon(outcome))
                        .font(.system(size: 10))
                        .foregroundStyle(outcomeColor(outcome))
                    Text(outcome.message)
                        .font(.system(size: 10))
                        .foregroundStyle(outcome.isFailure ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.leading, 44)
                .padding(.trailing, 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func outcomeIcon(_ o: AdoptOutcome) -> String {
        switch o {
        case .success: return "checkmark.circle.fill"
        case .mismatch: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        case .unknown: return "info.circle"
        }
    }

    private func outcomeColor(_ o: AdoptOutcome) -> AnyShapeStyle {
        switch o {
        case .success: return AnyShapeStyle(Color.green)
        case .mismatch: return AnyShapeStyle(Color.orange)
        case .failure: return AnyShapeStyle(Color.red)
        case .unknown: return AnyShapeStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private func adoptButton(title: String, force: Bool, filled: Bool) -> some View {
        Button {
            Task {
                await metrics.adopt(
                    token: effectiveToken,
                    force: force,
                    casks: casks,
                    managedTokens: managedTokens,
                    cli: appData.cli,
                    appData: appData
                )
                // Refresh the Installed list so the adopted app is recognized
                // as managed everywhere in the app.
                await appData.refreshInstalled()
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    filled
                        ? (force ? AnyShapeStyle(Color.white) : AnyShapeStyle(ActionColors.adoptText))
                        : AnyShapeStyle(ActionColors.adopt)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    filled ? AnyShapeStyle(force ? ActionColors.update : ActionColors.adopt)
                           : AnyShapeStyle(ActionColors.adopt.opacity(0.14)),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
    }
}
