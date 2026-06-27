import SwiftUI
import AppKit

// MARK: - DiskUsageSheet
//
// Shows where Homebrew's disk space goes: a headline total, then a row per
// location (apps / formulae / caskroom / download cache / taps) with a proportional
// bar, size, and a note on what it is and whether it's reclaimable. Mirrors the
// other Maintenance sheets: a single definite frame (so AppKit lays out in one
// pass and avoids _NSDetectedLayoutRecursion) with a header (Re-measure + Done)
// and measuring / content states.
//
// This is a read-only overview — the actual reclaiming happens via the existing
// "Deep Cache Cleanup" action. The footer points the user there.
struct DiskUsageSheet: View {
    @Bindable var metrics: MaintenanceMetrics
    let cli: BrewCLIService
    // Summed size of cask app bundles in /Applications, computed by the parent
    // from InstalledPackage.sizeBytes (those bundles live outside the prefix).
    // Passed straight through to the measurement so Re-measure stays accurate.
    let caskAppsBytes: Int64
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
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
            Image(systemName: "internaldrive")
                .foregroundStyle(.teal)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Disk Usage")
                    .font(.system(size: 15, weight: .bold))
                Text("How much space Homebrew uses on this Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // Refresh sits just to the right of the title, matching the main pages.
            PageRefreshButton("Re-measure", isWorking: metrics.footprintMeasuring, size: .compact, showsSpinner: false) {
                Task { await metrics.loadDiskFootprint(cli: cli, caskAppsBytes: caskAppsBytes) }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        // Two states only — unlike the streaming security/vuln scans, the
        // footprint is measured in one shot (du across the prefix), so we show a
        // single spinner while measuring and then the full breakdown at once.
        if metrics.footprintMeasuring {
            VStack(spacing: 10) {
                ProgressView()
                Text("Measuring disk usage…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    totalBlock
                    Divider()
                    // One row per measured location; fraction(of:) gives each
                    // row's share of the total so its bar can be drawn
                    // proportionally without the row knowing the grand total.
                    VStack(spacing: 12) {
                        ForEach(metrics.diskFootprint.components) { component in
                            FootprintRow(component: component,
                                         fraction: metrics.diskFootprint.fraction(of: component))
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    // Headline total + reclaimable hint.
    private var totalBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Total Homebrew footprint")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(metrics.diskFootprint.totalString)
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
            if metrics.diskFootprint.reclaimableBytes > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("Up to \(metrics.diskFootprint.reclaimableString) is reclaimable via Cache Cleanup")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if metrics.footprintMeasuring {
                ProgressView().scaleEffect(0.6)
                Text("Measuring…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Cache Cleanup frees the download cache; installed apps and their Caskroom installers stay")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}

// MARK: - FootprintRow
//
// One footprint location: icon + title + size on top, a proportional bar in the
// component's tint, then an explanation and the measured path (with Reveal in
// Finder).
struct FootprintRow: View {
    let component: DiskFootprintComponent
    let fraction: Double

    // Fixed track width so the bar needs no GeometryReader. Sized a bit under
    // the sheet's inner content width (560pt sheet − 20pt padding each side =
    // 520) to leave headroom for the ScrollView's scroller gutter — if the bar
    // is exactly the content width, AppKit can squeeze a sibling to a negative
    // width on the first layout pass ("Invalid view geometry: width is
    // negative").
    private static let barWidth: CGFloat = 496

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(tint.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: component.kind.systemImage)
                        .font(.system(size: 14))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(component.kind.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(component.kind.explanation)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(component.sizeString)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .layoutPriority(1)
            }

            // Proportional bar. We avoid GeometryReader (a known contributor to
            // AppKit layout recursion in this app). The fill width is the only
            // explicit width here; the track itself fills the row's definite
            // width via maxWidth so we don't stack competing fixed widths (which
            // can trigger re-entrant layout / _NSDetectedLayoutRecursion).
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 6)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(Self.barWidth, Self.barWidth * fraction)), height: 6)
            }

            // Measured path + Reveal in Finder.
            if let path = component.path {
                HStack(spacing: 6) {
                    Text(path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
            }
        }
        // One definite outer width for the whole row. Children fill this via
        // their natural sizing / maxWidth instead of each asserting their own
        // fixed width — a single source of truth avoids the layout recursion.
        .frame(width: Self.barWidth, alignment: .leading)
    }

    // Maps the model's color token to a concrete SwiftUI Color, keeping the
    // model free of SwiftUI.
    private var tint: Color {
        switch component.kind.tint {
        case .blue:   return .blue
        case .teal:   return .teal
        case .purple: return .purple
        case .orange: return .orange
        case .gray:   return .gray
        case .green:  return .green
        case .red:    return .red
        case .yellow: return .yellow
        }
    }
}
