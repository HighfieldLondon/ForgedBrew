import SwiftUI
import AppKit

// MARK: - SidebarView
//
// The app's primary navigation sidebar (left column of the NavigationSplitView).
// Renders every top-level destination grouped into sections — Discover, Categories,
// Formulae, Organization, Installed and Updates, Maintenance — and binds the
// user's choice back to the parent via `selection: SidebarItem?`. Most rows carry
// a live count: an accent capsule `badge` for actionable counts (updates waiting)
// or a muted gray `total` for passive totals (favorites, installed, taps), all
// sourced from AppDataService / AppUpdateService. The bottom status bar shows the
// Homebrew version and the light/dark appearance toggle. The reusable row/header
// components (SidebarSectionHeader, NavRow, CategoryDot, CategoryRow,
// FormulaeCategoryRow, BottomStatusBar) are defined first; SidebarView itself
// assembles them at the end.

// Dark-green, bold, slightly larger sidebar section header. Replaces the
// default small grey uppercase headers so the section names (Discover,
// Categories, etc.) read clearly. The green is tuned to stay legible on the
// translucent sidebar in both light and dark appearance.
struct SidebarSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color(red: 0.16, green: 0.50, blue: 0.28))
            .textCase(nil)
    }
}

/// A single tappable navigation entry: SF Symbol icon, label, and an optional
/// trailing count. The two count slots are semantically distinct — `badge` is the
/// accent capsule for actionable counts, `total` the muted gray for passive
/// totals — and a row may show either, both, or neither.
struct NavRow: View {
    let icon: String
    let label: String
    // Accent capsule count for ACTIONABLE counts (updates available).
    let badge: Int?
    // Subtle gray count for passive TOTALS (favorites, tags, parked,
    // apps). Reads as informational, distinct from the accent badge.
    var total: Int? = nil
    // Per-row icon tint so each sidebar item reads with a little color
    // instead of a uniform grey. Defaults to .secondary to stay safe for
    // any caller that doesn't pass one.
    var iconColor: Color = .secondary

    init(icon: String, label: String, badge: Int?, total: Int? = nil, iconColor: Color = .secondary) {
        self.icon = icon
        self.label = label
        self.badge = badge
        self.total = total
        self.iconColor = iconColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 20, height: 20)
                .foregroundStyle(iconColor)
            Text(label)
                .font(.system(size: 13))
            Spacer()
            if let total, total > 0 {
                Text("\(total)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// The small colored dot shown beside each cask category in the sidebar. Each
/// CaskCategory maps to a fixed hue so categories stay visually distinguishable
/// at a glance; the same palette is intended to read on the translucent sidebar.
struct CategoryDot: View {
    let category: CaskCategory

    var color: Color {
        switch category {
        case .fonts:
            return Color(red: 0.6, green: 0.3, blue: 0.8)
        case .mediaAndCreative:
            return Color(red: 0.80, green: 0.35, blue: 0.50)
        case .developerTools:
            return Color(red: 0.20, green: 0.45, blue: 0.72)
        case .macosUtilities:
            return Color(red: 0.45, green: 0.50, blue: 0.58)
        case .productivity:
            return Color(red: 0.86, green: 0.52, blue: 0.20)
        case .hardwareAndDrivers:
            return Color(red: 0.5, green: 0.5, blue: 0.55)
        case .internetAndBrowsers:
            return Color(red: 0.22, green: 0.56, blue: 0.66)
        case .fileManagement:
            return Color(red: 0.0, green: 0.5, blue: 0.7)
        case .privacyAndSecurity:
            return Color(red: 0.80, green: 0.25, blue: 0.28)
        case .gamesAndEmulators:
            return Color(red: 1.0, green: 0.5, blue: 0.0)
        case .aiAndML:
            return Color(red: 0.52, green: 0.40, blue: 0.72)
        case .cloudAndDevOps:
            return Color(red: 0.2, green: 0.6, blue: 1.0)
        case .scienceAndData:
            return Color(red: 0.0, green: 0.7, blue: 0.5)
        case .financeAndCrypto:
            return Color(red: 0.1, green: 0.7, blue: 0.3)
        case .databases:
            return Color(red: 0.8, green: 0.4, blue: 0.0)
        case .virtualizationAndRemote:
            return Color(red: 0.4, green: 0.4, blue: 0.9)
        case .networking:
            return Color(red: 0.0, green: 0.6, blue: 0.6)
        case .terminalAndShell:
            return Color(red: 0.22, green: 0.55, blue: 0.34)
        case .educationAndReference:
            return Color(red: 0.85, green: 0.65, blue: 0.13)
        case .other:
            return Color(red: 0.55, green: 0.53, blue: 0.50)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

// A sidebar category entry. Categories that have subcategories render as an
// expandable DisclosureGroup: the labeled parent row selects the whole category,
// and each child row selects that category filtered to one subcategory. Flat
// categories (Fonts, Other, single-subcategory ones) render as a plain row.
struct CategoryRow: View {
    let category: CaskCategory
    @Environment(AppDataService.self) var appData
    @State private var isExpanded = false

    private var subcategories: [String] {
        // Order by SIZE (most casks first) so the sidebar subcategory order
        // matches the size-ordered scrolling list in BrowseView. Ties (and
        // subcategories with no counted casks yet) fall back to the
        // classifier's canonical order so the list stays stable while counts
        // are still loading.
        let canonical = CaskClassifier.subcategories(for: category)
        let counts = appData.subcategoryCounts[category] ?? [:]
        let canonicalIndex = Dictionary(
            uniqueKeysWithValues: canonical.enumerated().map { ($1, $0) }
        )
        return canonical.sorted { lhs, rhs in
            let lc = counts[lhs] ?? 0
            let rc = counts[rhs] ?? 0
            if lc != rc { return lc > rc }
            let li = canonicalIndex[lhs] ?? Int.max
            let ri = canonicalIndex[rhs] ?? Int.max
            return li < ri
        }
    }

    private var categoryCount: Int? {
        let c = appData.categoryCounts[category] ?? 0
        return c > 0 ? c : nil
    }

    // Header row content (dot + name + count), reused by both the plain and
    // disclosure variants.
    private var header: some View {
        HStack(spacing: 8) {
            CategoryDot(category: category)
            Text(category.displayName)
                .font(.system(size: 13))
            Spacer()
            if let count = categoryCount {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        if subcategories.isEmpty {
            header.tag(SidebarItem.category(category))
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(subcategories, id: \.self) { sub in
                    HStack(spacing: 8) {
                        Text(sub)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let subCount = appData.subcategoryCounts[category]?[sub], subCount > 0 {
                            Text("\(subCount)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 1)
                    .padding(.leading, 16)
                    .tag(SidebarItem.subcategory(category, sub))
                }
            } label: {
                header.tag(SidebarItem.category(category))
            }
        }
    }
}

// The single "Formulae" sidebar category. Like CategoryRow it renders as an
// expandable DisclosureGroup: the parent row selects ALL formulae, and each
// child row scopes to one CLI-tool subcategory. Formulae are a single-level
// taxonomy, so the subcategory list comes straight from FormulaClassifier and
// the counts come from appData.formulaSubcategoryCounts (a flat map).
struct FormulaeCategoryRow: View {
    @Environment(AppDataService.self) var appData
    @State private var isExpanded = false

    private var subcategories: [String] {
        // Order by SIZE (most formulae first) so the sidebar matches the
        // size-ordered scrolling list in FormulaBrowseView. Subcategories with
        // no counted formulae fall back to the classifier's canonical order so
        // the list stays stable before counts have loaded.
        let counts = appData.formulaSubcategoryCounts
        let canonical = FormulaClassifier.subcategories()
        let canonicalIndex = Dictionary(
            uniqueKeysWithValues: canonical.enumerated().map { ($1, $0) }
        )
        let undefined = FormulaClassifier.undefinedSubcategory
        return canonical.sorted { lhs, rhs in
            // "Undefined" always sorts last regardless of count.
            let lUndef = (lhs == undefined)
            let rUndef = (rhs == undefined)
            if lUndef != rUndef { return rUndef }
            let lc = counts[lhs] ?? 0
            let rc = counts[rhs] ?? 0
            if lc != rc { return lc > rc }
            let li = canonicalIndex[lhs] ?? Int.max
            let ri = canonicalIndex[rhs] ?? Int.max
            return li < ri
        }
    }

    private var totalCount: Int? {
        appData.formulaCount > 0 ? appData.formulaCount : nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            // A distinct terminal glyph instead of a CategoryDot (which is keyed
            // to CaskCategory) so Formulae reads clearly as its own thing.
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .frame(width: 8, height: 8)
            Text("Formulae")
                .font(.system(size: 13))
            Spacer()
            if let count = totalCount {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(subcategories, id: \.self) { sub in
                HStack(spacing: 8) {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let subCount = appData.formulaSubcategoryCounts[sub], subCount > 0 {
                        Text("\(subCount)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 1)
                .padding(.leading, 16)
                .tag(SidebarItem.formulaSubcategory(sub))
            }
        } label: {
            header.tag(SidebarItem.formulaeRoot)
        }
    }
}

/// Pinned footer of the sidebar: a green status dot plus the running Homebrew
/// version on the left, and the light/dark appearance toggle on the right. The
/// dark-mode preference is persisted in UserDefaults and applied app-wide (every
/// window) so an explicit choice overrides the system setting and stays in sync
/// with the Settings window.
struct BottomStatusBar: View {
    @Environment(AppDataService.self) var appData
    @AppStorage("forgedbrewPrefersDarkMode") private var isDark: Bool = true

    private func applyAppearance() {
        // Explicit light/dark (not nil) so an explicit choice always wins over
        // the system setting, and apply to every window so the Settings window
        // and main window stay in lockstep. Mirrors GeneralSettingsTab.setDark.
        let appearance: NSAppearance? = isDark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        NSApp.appearance = appearance
        for window in NSApp.windows { window.appearance = appearance }
    }

    var body: some View {
        HStack {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
            Text(appData.homebrewVersion.isEmpty ? "Homebrew" : appData.homebrewVersion)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                isDark.toggle()
                applyAppearance()
            } label: {
                Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { applyAppearance() }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Environment(AppDataService.self) var appData

    var installedCount: Int { appData.installedPackages.count }
    // Updates badge shows only packages that will actually be offered for
    // upgrade — parked packages are excluded (they're held out of the Updates
    // list and Update All).
    var outdatedCount: Int { appData.outdatedExcludingParked().count }
    // Total parked items, matching what the Parked screen shows: parked
    // Homebrew packages PLUS parked Mac App Store / Other (non-Homebrew) app
    // updates, which live in a separate service.
    var parkedCount: Int { appData.parkedRecords.count + AppUpdateService.shared.parkedList().count }
    // App Updates badge counts non-Homebrew apps (App Store / Sparkle / GitHub)
    // with a newer version available, excluding ones the user has parked. Reads
    // the shared AppUpdateService so the badge updates after a scan.
    var appUpdateCount: Int { AppUpdateService.shared.visibleUpdates().count }
    // Total non-Homebrew apps (Mac Store + other) discovered on this Mac,
    // regardless of whether an update is available. Drives the gray total
    // on the "Mac Store/Other Apps" row, mirroring the Homebrew layout.
    var macOtherTotal: Int { AppUpdateService.shared.allApps.count }
    // Number of Homebrew taps (source repositories) the user has added.
    var tapCount: Int { appData.tapCount }

    var body: some View {
        List(selection: $selection) {
            // Discover: catalog entry points — the home feed and the curated
            // popularity views (trending now, 3-month trend, top of the past
            // year) plus "Browse All". No counts; these are destinations.
            Section(header: SidebarSectionHeader("Discover")) {
                NavRow(icon: "house", label: "Home", badge: nil, iconColor: Color(red: 0.20, green: 0.45, blue: 0.72))
                    .tag(SidebarItem.home)
                NavRow(icon: "chart.line.uptrend.xyaxis", label: "Currently Trending", badge: nil, iconColor: Color(red: 0.86, green: 0.52, blue: 0.20))
                    .tag(SidebarItem.trending)
                NavRow(icon: "calendar", label: "3-Month Trend", badge: nil, iconColor: Color(red: 0.20, green: 0.55, blue: 0.58))
                    .tag(SidebarItem.recentlyUpdated)
                NavRow(icon: "crown", label: "Top Past Year", badge: nil, iconColor: Color(red: 0.82, green: 0.65, blue: 0.18))
                    .tag(SidebarItem.topPastYear)
                NavRow(icon: "square.grid.2x2", label: "Browse All", badge: nil, iconColor: Color(red: 0.52, green: 0.40, blue: 0.72))
                    .tag(SidebarItem.browseAll)
            }

            // Categories: one expandable CategoryRow per cask category, each
            // drilling into its subcategories. Casks (GUI apps) only.
            Section(header: SidebarSectionHeader("Categories")) {
                ForEach(CaskCategory.allCases, id: \.self) { cat in
                    CategoryRow(category: cat)
                }
            }

            // Formulae (CLI tools) live in their own section as a single
            // expandable row, since they're a flat one-level taxonomy unlike the
            // category-per-row casks above.
            Section(header: SidebarSectionHeader("Formulae")) {
                FormulaeCategoryRow()
            }

            // Organization: the user's own curation surfaces — apps they've
            // flagged, annotated, or held back. Personal lists, not machine state.
            Section(header: SidebarSectionHeader("Organization")) {
                NavRow(icon: "heart", label: "Favorites", badge: nil, total: appData.favoriteTokens.count, iconColor: Color(red: 0.80, green: 0.25, blue: 0.28))
                    .tag(SidebarItem.favorites)
                NavRow(icon: "tag", label: "Notes & Tags", badge: nil, total: appData.notesAndTagsCount, iconColor: Color(red: 0.34, green: 0.36, blue: 0.66))
                    .tag(SidebarItem.notes)
                NavRow(icon: "parkingsign.circle", label: "Parked", badge: nil, total: parkedCount, iconColor: Color(red: 0.60, green: 0.42, blue: 0.24))
                    .tag(SidebarItem.parked)
            }

            // Installed and Updates: what's on this Mac plus every place a newer
            // version may be waiting — Homebrew packages and non-Homebrew apps
            // (App Store, Sparkle, GitHub). (Brewfile import/export now lives on
            // the Maintenance screen.)
            Section(header: SidebarSectionHeader("Installed and Updates")) {
                NavRow(icon: "internaldrive", label: "Installed Homebrew Apps and Formulae", badge: nil, total: installedCount, iconColor: Color(red: 0.22, green: 0.55, blue: 0.34))
                    .tag(SidebarItem.installed)
                // Indented (leading 16) to read as a child of the Installed row
                // above it. Carries the accent badge of actionable Homebrew
                // updates (parked packages already excluded by outdatedCount).
                NavRow(icon: "arrow.up.circle", label: "Homebrew Updates", badge: outdatedCount > 0 ? outdatedCount : nil, iconColor: Color(red: 0.20, green: 0.45, blue: 0.72))
                    .padding(.leading, 16)
                    .tag(SidebarItem.updates)
                NavRow(icon: "app.badge", label: "Mac Store/Other Apps", badge: nil, total: macOtherTotal, iconColor: Color(red: 0.22, green: 0.56, blue: 0.66))
                    .tag(SidebarItem.appUpdates)
                // Indented child of the Mac Store/Other Apps row, mirroring the
                // Homebrew Installed/Updates pairing above. Badge counts only
                // apps with an update available and not parked.
                NavRow(icon: "arrow.up.circle", label: "Mac Store/Other Apps Updates", badge: appUpdateCount > 0 ? appUpdateCount : nil, iconColor: Color(red: 0.22, green: 0.56, blue: 0.66))
                    .padding(.leading, 16)
                    .tag(SidebarItem.appUpdatesOnly)
                NavRow(icon: "shippingbox", label: "Taps", badge: nil, total: tapCount, iconColor: Color(red: 0.74, green: 0.48, blue: 0.22))
                    .tag(SidebarItem.taps)
            }

            // Maintenance: housekeeping and configuration — the deeper tools and
            // app settings, kept out of the way at the bottom.
            Section(header: SidebarSectionHeader("Maintenance")) {
                NavRow(icon: "wrench.and.screwdriver", label: "Maintenance", badge: nil, iconColor: Color(red: 0.36, green: 0.45, blue: 0.78))
                    .tag(SidebarItem.maintenance)
                NavRow(icon: "gearshape", label: "Settings", badge: nil, iconColor: Color(red: 0.50, green: 0.40, blue: 0.66))
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .listRowSeparator(.hidden)
        .background(.ultraThinMaterial)
        // Kill the macOS 26 toolbar scroll-edge fade that ghosts the first
        // section header ("Discover") at the top of the sidebar.
        .hardScrollEdge(.top)
        // Top inset so the first section header clears the window title bar
        // instead of being tucked partly beneath it, and so the list can scroll
        // its top row fully into view. 8pt was shorter than the title-bar height,
        // which left the first row clipped and unreachable at the top of the
        // scroll. Reserve the full title-bar gap (28pt) so the top of the list is
        // both visible and scrollable.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 28)
        }
        .safeAreaInset(edge: .bottom) {
            BottomStatusBar()
        }
        .navigationTitle("ForgedBrew")
    }
}

#Preview {
    NavigationSplitView {
        SidebarView(selection: .constant(SidebarItem.home))
            .environment(AppDataService.shared)
    } detail: {
        Text("Home")
            .font(.title)
            .padding()
    }
}
