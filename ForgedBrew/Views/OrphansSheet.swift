import SwiftUI
import AppKit

// MARK: - OrphansSheet
//
// Lists formulae Homebrew keeps only as dependencies that nothing installed now
// requires (`brew autoremove`'s candidates) and lets the user remove them one at
// a time or all at once. Mirrors DuplicatesSheet/AdoptSheet: a fixed-size sheet
// (single definite width so AppKit lays out in one pass and avoids
// _NSDetectedLayoutRecursion), header with Re-scan + Done, a caution bar, and
// scanning / empty / list states.
//
// Each package shows its token, version, on-disk size, and Cellar path (with
// Reveal in Finder), plus a Remove button. The footer shows the reclaimable
// total and a "Remove All" button that runs `brew autoremove`. Failures surface
// inline in red on the affected row (per-package) or in the footer area (Remove
// All), and the list stays visible so the user sees exactly what went wrong.
struct OrphansSheet: View {
    @Bindable var metrics: MaintenanceMetrics
    let cli: BrewCLIService
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool {
        metrics.orphansScanning
            || !metrics.removingOrphanTokens.isEmpty
            || metrics.removingAllOrphans
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
        // Single definite width (see AdoptSheet) to keep AppKit's layout to one
        // top-down pass.
        .frame(width: 620, height: 560)
        // Sheets don't reliably inherit the WindowGroup's
        // .progressViewStyle(.forgedbrew), so re-apply it here: otherwise the
        // bare ProgressView()s fall back to the AppKit NSProgressIndicator,
        // which ghosts a grey spinner at the sheet's top-center during
        // re-layout. See SecurityScanSheet / ForgedBrewSpinner for details.
        .progressViewStyle(.forgedbrew)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "leaf")
                .foregroundStyle(.orange)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Orphaned Packages")
                    .font(.system(size: 15, weight: .bold))
                Text("Formulae kept only as now-unneeded dependencies")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // Re-scan sits just to the right of the title, matching the main pages.
            PageRefreshButton("Re-scan", isWorking: busy, size: .compact, showsSpinner: false) {
                rescan()
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Caution note

    private var warningBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text("These were installed automatically and nothing needs them now. Removing them is safe and frees disk space; Homebrew will reinstall any if a future package needs it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        if metrics.orphansScanning {
            VStack(spacing: 10) {
                ProgressView()
                Text("Scanning for orphaned packages…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if metrics.orphanResult.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                Text("No orphaned packages")
                    .font(.system(size: 13, weight: .medium))
                Text("Every installed formula is either something you asked for or still needed by another package.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(metrics.orphanResult.packages) { package in
                        OrphanedPackageRow(package: package, metrics: metrics, cli: cli)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            // Top-level "Remove All" error, if the autoremove run failed.
            if let allError = metrics.orphanRemoveAllError, !allError.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(allError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 10) {
                if metrics.removingAllOrphans {
                    ProgressView().scaleEffect(0.6)
                    Text("Removing all…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                let count = metrics.orphanResult.packages.count
                if count > 0 {
                    Text("Reclaims ~\(metrics.orphanResult.totalReclaimableString)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await metrics.removeAllOrphans(cli: cli) }
                    } label: {
                        Text("Remove All (\(count))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                } else {
                    Text("No orphaned packages")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private func rescan() {
        Task { await metrics.loadOrphans(cli: cli) }
    }
}

// MARK: - OrphanedPackageRow
//
// One orphaned formula: leaf icon + token + version/size on top, the Cellar path
// (with Reveal in Finder) beneath, and a Remove button. Failures surface inline
// in red and the row stays visible.
struct OrphanedPackageRow: View {
    let package: OrphanedPackage
    @Bindable var metrics: MaintenanceMetrics
    let cli: BrewCLIService

    var body: some View {
        let isRemoving = metrics.removingOrphanTokens.contains(package.token)
        let error = metrics.orphanErrors[package.token]

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "leaf")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(package.token)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if let v = package.version {
                            Text("v\(v)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text("· \(package.sizeString)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if let path = package.cellarPath {
                        Text(path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if let path = package.cellarPath {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }

                if isRemoving {
                    ProgressView().scaleEffect(0.5).frame(width: 70)
                } else {
                    Button {
                        Task { await metrics.removeOrphan(package, cli: cli) }
                    } label: {
                        Text("Remove")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(metrics.removingAllOrphans || !metrics.removingOrphanTokens.isEmpty)
                }
            }

            if let error, !error.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 10))
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
