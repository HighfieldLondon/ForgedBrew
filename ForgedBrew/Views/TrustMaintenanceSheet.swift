import SwiftUI
import AppKit

// MARK: - TrustMaintenanceSheet
//
// Proactive heads-up for an upcoming Homebrew change. By September 1, 2026,
// Homebrew is removing casks that fail macOS Gatekeeper (unsigned/unnotarized)
// from the official tap and dropping its quarantine workaround
// (Homebrew/brew#20755). IMPORTANT distinction so the copy stays honest:
//   • Installed apps are NOT deleted or disabled. They keep running.
//   • What is lost is the UPDATE PATH — once a cask leaves the official tap,
//     Homebrew can no longer upgrade or track that app, so it goes stale.
//   • Clearing the quarantine flag here lets a Gatekeeper-rejected app keep
//     LAUNCHING, but it does NOT restore updates. Nothing the app does locally
//     can bring a removed cask back into Homebrew's update path.
//
// This sheet lists the at-risk apps (Gatekeeper rejects them today, excluding
// Apple system binaries) and lets the user clear the quarantine flag now — on
// the apps they trust — one at a time or all at once, so those apps keep
// opening. The action is `xattr -d com.apple.quarantine <app>` (no sudo) via
// removeQuarantine(at:). The copy is careful to frame this as "keeps it
// running, not updating", not as a full fix.
//
// Mirrors OrphansSheet/AdoptSheet: a single fixed frame (so AppKit lays out in
// one pass and avoids _NSDetectedLayoutRecursion), header with Re-scan + Done,
// a warning bar explaining the change, and scanning / empty / list states. Each
// app shows its name, token, why Gatekeeper rejects it, and its bundle path
// (with Reveal in Finder), plus a Trust button. The footer carries a caution
// line and a "Trust All" button. Failures surface inline in red per-row.
struct TrustMaintenanceSheet: View {
    @Bindable var metrics: MaintenanceMetrics
    let cli: BrewCLIService
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool {
        metrics.trustScanning || !metrics.trustingPaths.isEmpty
    }

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
        // Single definite size (see OrphansSheet) to keep AppKit's layout to one
        // top-down pass.
        .frame(width: 640, height: 580)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.blue)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Trust Maintenance")
                    .font(.system(size: 15, weight: .bold))
                Text("Apps Homebrew will stop updating after an upcoming change")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // Re-scan sits just to the right of the title, matching the main pages.
            PageRefreshButton("Re-scan", isWorking: busy, size: .compact) {
                rescan()
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        // Padding so the title/subtitle and the Re-scan/Done buttons aren't
        // jammed against the window's top and right edges (the buttons were
        // getting clipped in the top-right corner).
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
    // MARK: Change-explanation warning bar
    private var warningBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("From September 1, 2026, Homebrew is removing casks that fail macOS Gatekeeper from its official tap. These apps won’t be deleted and will keep running — but Homebrew will no longer update or track them, so they’ll go stale. Clearing the quarantine flag now — only on apps you trust — keeps them launching; it does not restore Homebrew updates. For an app you rely on, look for a signed alternative.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        // Inset the warning copy from the window edges so it isn't flush against
        // the sides, and give it vertical room from the divider above/below.
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.08))
    }
    // MARK: Content states
    @ViewBuilder
    private var content: some View {
        if metrics.trustScanning {
            scanningProgress
        } else if metrics.gatekeeperRiskResult.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                Text("Nothing at risk")
                Text(metrics.trustHasScanned
                     ? "Every installed app passes Gatekeeper on its own, so the upcoming Homebrew change won’t affect their updates."
                     : "Run a scan to check your installed apps against the upcoming Homebrew change.")
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Clean app list: each row is just the app (icon, name,
                    // token, path) plus its Trust / Reveal actions. The reason
                    // each app is flagged now lives in the framed box below the
                    // list, so the list itself stays scannable.
                    ForEach(metrics.gatekeeperRiskResult.risks) { risk in
                        GatekeeperRiskRow(risk: risk, metrics: metrics, cli: cli)
                        Divider().padding(.leading, 16)
                    }
                    // Shared, framed explanation box beneath the list. Collects
                    // every flagged app's specific Gatekeeper reason in one place
                    // so the rows can stay clean while the detail is preserved.
                    warningDetailBox
                }
            }
        }
    }
    // MARK: Live scan progress
    private var scanningProgress: some View {
        VStack(spacing: 14) {
            ProgressView(
                value: Double(metrics.trustScannedCount),
                total: Double(max(metrics.trustTotalCount, 1))
            )
            .progressViewStyle(.linear)
            .frame(maxWidth: 360)
            VStack(spacing: 4) {
                if metrics.trustTotalCount > 0 {
                    Text("Scanning \(metrics.trustScannedCount) of \(metrics.trustTotalCount)…")
                } else {
                    Text("Preparing scan…")
                }
                if let current = metrics.trustCurrentApp, !current.isEmpty {
                    Text(current)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text("This scan can take a few minutes — depending on how many apps are being checked. macOS runs a full Gatekeeper assessment on each one.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // MARK: Shared warning detail box (below the app list)
    private var warningDetailBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Why these apps are flagged")
            }
            Text("Each app above fails macOS Gatekeeper on its own and still carries the “downloaded from the internet” quarantine flag. After September 1, 2026, Homebrew drops these casks from its official tap: the apps keep running but stop receiving Homebrew updates. Clearing the quarantine flag keeps a trusted app launching cleanly today — it doesn’t bring updates back. Here’s the specific reason each is flagged:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(metrics.gatekeeperRiskResult.risks) { risk in
                    HStack(alignment: .top, spacing: 6) {
                        Text(risk.appName)
                            .frame(width: 130, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(risk.reason)
                                .fixedSize(horizontal: false, vertical: true)
                            if let authority = risk.signingAuthority, !authority.isEmpty {
                                Text(authority)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
    // MARK: Footer
    private var footer: some View {
        VStack(spacing: 8) {
            // Top-level "Trust All" error, if any app in the batch failed.
            if let allError = metrics.trustAllError, !allError.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                    Text(allError)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                Text("Keeps trusted apps launching — not updating. Only trust sources you recognize.")
                Spacer()
                let count = metrics.gatekeeperRiskResult.count
                if count > 0 {
                    Button {
                        Task { await metrics.trustAllApps(cli: cli) }
                    } label: {
                        Text("Trust All (\(count))")
                    }
                    .buttonStyle(PillActionButtonStyle())
                    .disabled(busy)
                }
            }
        }
        .padding(16)
    }

    private func rescan() {
        Task { await metrics.loadGatekeeperRisks(cli: cli) }
    }
}

// MARK: - GatekeeperRiskRow
//
// One at-risk app, kept deliberately clean: shield icon + app name + token, the
// bundle path with Reveal in Finder, and a Trust button. The reason Gatekeeper
// rejects it (and its signing authority) lives in the shared framed box below
// the list, not here, so the list stays scannable. Failures surface inline in
// red and the row stays visible.
struct GatekeeperRiskRow: View {
    let risk: GatekeeperRisk
    @Bindable var metrics: MaintenanceMetrics
    let cli: BrewCLIService

    var body: some View {
        let isTrusting = metrics.trustingPaths.contains(risk.appPath)
        let error = metrics.trustErrors[risk.appPath]

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 6) {
                    Text(risk.appName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(risk.token)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: risk.appPath)]
                    )
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                if isTrusting {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button {
                        Task { await metrics.trustApp(risk, cli: cli) }
                    } label: {
                        Text("Trust")
                    }
                    .buttonStyle(PillActionButtonStyle(cornerRadius: 7))
                    .disabled(!metrics.trustingPaths.isEmpty || metrics.trustScanning)
                }
            }

            // Bundle path (monospaced, middle-truncated) so the user can see
            // exactly which app this is.
            Text(risk.appPath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 38)

            if let error, !error.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
