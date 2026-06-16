import SwiftUI
import AppKit

// MARK: - DuplicatesSheet
//
// Lists apps/tools installed more than once and lets the user remove the extra
// copy. Mirrors AdoptSheet's structure: a fixed-size sheet (single definite
// width so AppKit lays out in one pass and avoids _NSDetectedLayoutRecursion),
// header with Re-scan + Done, and scanning / empty / list states.
//
// Each DuplicateGroup renders the app once with its two+ installations beneath
// it. Every removable install has a Remove button; the App Store copy is shown
// read-only with a hint (must be removed via Launchpad/Finder). Failures surface
// inline in red on the affected install, and the group stays visible so the user
// sees exactly what went wrong (e.g. the OneDrive / permissions cases).
struct DuplicatesSheet: View {
    @Bindable var metrics: MaintenanceMetrics
    let casks: [CaskMetadata]
    let installedCaskTokens: Set<String>
    let installedFormulaTokens: Set<String>
    let cli: BrewCLIService
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool { metrics.duplicatesScanning || !metrics.removingDuplicateIDs.isEmpty }

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
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.purple)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate Installs")
                    .font(.system(size: 15, weight: .bold))
                Text("Apps or tools installed more than once on this Mac")
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
        .padding(16)
    }

    // MARK: Caution note

    private var warningBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text("Removing a copy is permanent for Homebrew installs and moves App Store and manual apps to the Trash. Keep the copy you actually use. If you want to keep both on purpose \u{2014} for example, different versions for testing \u{2014} just ignore this and leave them as they are.")
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
        if metrics.duplicatesScanning {
            VStack(spacing: 10) {
                ProgressView()
                Text("Scanning for duplicates…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if metrics.duplicateGroups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                Text("No duplicates found")
                    .font(.system(size: 13, weight: .medium))
                Text("Nothing is installed twice across the App Store, Homebrew, and your Applications folders.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(metrics.duplicateGroups) { group in
                        DuplicateGroupRow(
                            group: group,
                            metrics: metrics,
                            casks: casks,
                            installedCaskTokens: installedCaskTokens,
                            installedFormulaTokens: installedFormulaTokens,
                            cli: cli
                        )
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if !metrics.removingDuplicateIDs.isEmpty {
                ProgressView().scaleEffect(0.6)
                Text("Removing…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            let n = metrics.duplicateGroups.count
            Text(n == 0 ? "No duplicates" : "\(n) duplicate\(n == 1 ? "" : "s") found")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func rescan() {
        Task {
            await metrics.loadDuplicates(
                casks: casks,
                installedCaskTokens: installedCaskTokens,
                installedFormulaTokens: installedFormulaTokens,
                cli: cli
            )
        }
    }
}

// MARK: - DuplicateGroupRow
//
// One duplicate group: the app/tool name + kind badge on top, then a list of
// its installs, each with source label, version/size, Reveal in Finder, and a
// Remove button (or a read-only note for App Store).
struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    @Bindable var metrics: MaintenanceMetrics
    let casks: [CaskMetadata]
    let installedCaskTokens: Set<String>
    let installedFormulaTokens: Set<String>
    let cli: BrewCLIService

    // The App Store copy the user tapped Remove on, awaiting confirmation.
    // App Store apps are purchased, so we confirm before trashing the local
    // copy (the purchase record itself is unaffected). Homebrew/manual copies
    // remove directly without this step.
    @State private var pendingAppStoreRemoval: DuplicateInstall? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Group header: icon + name + kind badge.
            HStack(spacing: 10) {
                // For on-disk groups the displayName is the real app name, which
                // helps the icon service resolve the local bundle icon; the key
                // is a normalized fallback. AppIconView shows a letter
                // placeholder if neither resolves.
                AppIconView(token: group.key, displayName: group.displayName, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: group.kind.systemImage)
                            .font(.system(size: 9))
                        Text(group.kind.title)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.12), in: Capsule())
                }
                Spacer()
            }

            Text(group.kind.explanation)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Each installation.
            VStack(spacing: 6) {
                ForEach(group.installs) { install in
                    installRow(install)
                }
            }
            .padding(.leading, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .confirmationDialog(
            "Move this App Store copy to the Trash?",
            isPresented: Binding(
                get: { pendingAppStoreRemoval != nil },
                set: { if !$0 { pendingAppStoreRemoval = nil } }
            ),
            presenting: pendingAppStoreRemoval
        ) { install in
            Button("Move to Trash", role: .destructive) {
                performRemove(install)
                pendingAppStoreRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingAppStoreRemoval = nil }
        } message: { _ in
            Text("This moves the App Store copy to the Trash so you can recover it if needed. Your purchase stays in your Apple account \u{2014} you can re-download it from the App Store any time.")
        }
    }

    @ViewBuilder
    private func installRow(_ install: DuplicateInstall) -> some View {
        let isRemoving = metrics.removingDuplicateIDs.contains(install.id)
        let error = metrics.duplicateErrors[install.id]

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // Source dot.
                Circle()
                    .fill(sourceColor(install.source))
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(install.source.shortLabel)
                            .font(.system(size: 11, weight: .semibold))
                        if let v = install.version {
                            Text("v\(v)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let size = install.sizeString {
                            Text("· \(size)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let path = install.path {
                        Text(path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let token = install.source.brewToken {
                        Text(token)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if let path = install.path {
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
                } else if install.source.isRemovableFromForgedBrew {
                    Button {
                        requestRemove(install)
                    } label: {
                        Text("Remove")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(!metrics.removingDuplicateIDs.isEmpty)
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
                .padding(.leading, 15)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    // Routes a Remove tap: App Store copies stage a confirmation first (they're
    // purchased); every other source removes immediately.
    private func requestRemove(_ install: DuplicateInstall) {
        if install.source.needsRemovalConfirmation {
            pendingAppStoreRemoval = install
        } else {
            performRemove(install)
        }
    }

    // Actually removes the copy via the metrics view model (brew uninstall for
    // Homebrew sources, move-to-Trash for App Store / manual on-disk).
    private func performRemove(_ install: DuplicateInstall) {
        Task {
            await metrics.removeDuplicate(
                install,
                casks: casks,
                installedCaskTokens: installedCaskTokens,
                installedFormulaTokens: installedFormulaTokens,
                cli: cli
            )
        }
    }

    private func sourceColor(_ source: DuplicateSource) -> Color {
        switch source {
        case .appStore:        return .blue
        case .homebrewCask:    return .orange
        case .homebrewFormula: return .green
        case .manualOnDisk:    return .gray
        }
    }
}
