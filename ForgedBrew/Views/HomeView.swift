import SwiftUI
import AppKit

// MARK: - SectionHeader
struct SectionHeader: View {
    let title: String
    let action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.title3).fontWeight(.bold)
            Spacer()
            if let action {
                Button("See More", action: action)
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - FeaturedHeroCard
struct FeaturedHeroCard: View {
    let cask: CaskMetadata
    // The installed record for this cask (nil == not installed). Drives the
    // primary button's label/state so the hero card no longer shows a bare
    // "Install" for an app that's already on the Mac — the exact bug the user
    // hit with 0-ad showing installable on Home while installed on the detail
    // page.
    let installed: InstalledPackage?
    let onLearnMore: () -> Void
    @State private var isHovered = false

    private var isInstalled: Bool { installed != nil }

    var body: some View {
        HStack(spacing: 0) {
            // Left Panel
            VStack(alignment: .leading, spacing: 12) {
                AppIconView(token: cask.token, displayName: cask.displayName, homepage: cask.homepage, size: 64)

                Text(cask.displayName)
                    .font(.title)
                    .fontWeight(.bold)

                Text(cask.token)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)

                Text(cask.desc ?? "")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                Spacer()

                HStack(spacing: 12) {
                    // The featured card is a discovery surface, not an install
                    // surface: per the latest design it offers ONLY "Learn More"
                    // (the Install/Update action lives on the detail card the
                    // user lands on). This keeps Home from doubling as an install
                    // button and avoids the "Install shown for an already-installed
                    // app" confusion entirely. Opens the in-app detail page.
                    Button("Learn More") {
                        onLearnMore()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .controlSize(.large)
                }

                if cask.installCount30d > 0 {
                    Text("\(cask.installCount30d.formatted())+ installs in the last 30 days")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)

            // Right Panel — clear, text-based getting-started guidance.
            // (Replaces the old decorative mock-terminal block, which read as
            // real install output even though the app wasn't installed.)
            VStack(alignment: .leading, spacing: 14) {
                Label("Featured App", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isInstalled ? "checkmark.circle.fill" : "star.circle.fill")
                            .foregroundStyle(isInstalled ? Color.green : Color.accentColor)
                        Text(isInstalled
                             ? "\(cask.displayName) is already installed on your Mac."
                             : "A standout app we think is worth a look.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("Click **Learn More** to see screenshots, details, and install it.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(width: 240, alignment: .topLeading)
            .frame(maxHeight: .infinity)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 16, topTrailingRadius: 16))
        }
        .frame(minHeight: 220)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: isHovered ? .accentColor.opacity(0.2) : .clear, radius: 16, y: 0)
        .onHover { isHovered = $0 }
    }
}

// MARK: - TrendingRow
struct TrendingRow: View {
    let rank: Int
    let cask: CaskMetadata
    let installCount: Int
    // Period suffix for the install-count caption (e.g. "30d" or "90d").
    var periodLabel: String = "30d"

    var body: some View {
        HStack(spacing: 12) {
            // Rank number
            Text("\(rank)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 28)

            // Icon
            AppIconView(token: cask.token, displayName: cask.displayName, homepage: cask.homepage, size: 36)

            // Name + desc
            VStack(alignment: .leading, spacing: 2) {
                Text(cask.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(cask.desc ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Real install count over the selected period
            VStack(alignment: .trailing, spacing: 2) {
                Text(installCount > 0 ? "\(installCount.formatted())" : "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("installs / \(periodLabel)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - FormulaTrendingRow
// Ranked row for the home Formulae feed, mirroring TrendingRow but for CLI
// packages: rank number, terminal glyph, name (monospaced) + description, and
// 30-day install count.
struct FormulaTrendingRow: View {
    let rank: Int
    let formula: FormulaMetadata

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 28)

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.gradient)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(formula.name)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(formula.desc ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formula.installCount30d > 0 ? "\(formula.installCount30d.formatted())" : "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("installs / 30d")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - HomeFeedMode
// The home feed shows either the casks/apps catalog or the formulae catalog.
// The segmented toggle at the top of HomeView swaps the WHOLE feed between
// these two modes.
enum HomeFeedMode: String, CaseIterable {
    case apps = "Apps"
    case formulae = "Formulae"
}

// MARK: - HomeView
struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @Environment(AppDataService.self) var appData
    @State private var selectedCategory: CaskCategory? = nil
    // Which catalog the home feed is showing (Apps vs Formulae). Drives the
    // segmented toggle and swaps the entire feed below it.
    @State private var feedMode: HomeFeedMode = .apps
    // Persisted (in DetailRouter) so the scroll position survives the
    // detail-page round-trip and Back returns to where the user was.
    @Binding var scrollAnchor: CaskMetadata.ID?
    // Callback to navigate to browse with a category filter (passed from parent)
    var onCategorySelected: ((CaskCategory?) -> Void)?
    var onCaskTapped: ((CaskMetadata) -> Void)?
    // Navigate to a formula detail page (Formulae feed mode).
    var onFormulaTapped: ((FormulaMetadata) -> Void)?
    // Navigate to a sidebar Discover destination (used by the "See More" links
    // on the Currently Trending / 3-Month Trend home sections).
    var onShowSort: ((SidebarItem) -> Void)?

    // Live top-most card id, tracked via .scrollPosition (local @State, never
    // written to the @Observable VM during layout). Mirrored into scrollAnchor
    // on tap; seeded back from it on appear.
    @State private var scrolledID: CaskMetadata.ID? = nil

    // How many formulae the home feed currently shows. The full catalog is ~8k,
    // which nobody scrolls through end-to-end — so we show a page at a time with
    // a "Load More" button, and point users at the sidebar subcategories / search
    // for targeted browsing.
    private let formulaePageSize = 60
    @State private var formulaeVisibleCount = 60
    // The Formulae feed opens on a compact ranked list of the most-downloaded
    // formulae. "Show All" flips this to true, expanding the full A–Z catalog
    // inline (paged with "Load More") so the user stays on the home feed.
    @State private var showAllFormulae = false

    // Tracks an in-flight manual Refresh (drives button disabled state).
    @State private var isRefreshing = false
    // How many formulae appear in the default ranked list before "Show All".
    private let formulaeRankedCount = 48

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // App title header with the ForgedBrew mark, matching the other
                // screens. Home has no large page title of its own, so this is
                // where the icon-beside-name lives on the landing page.
                HStack(spacing: 12) {
                    PageTitleLabel(title: "ForgedBrew")
                    // Refresh sits just to the right of the page name, matching
                    // the other screens (forces a fresh catalog + analytics fetch).
                    PageRefreshButton(isWorking: catalogRefreshing) {
                        Task { await refreshHome() }
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)

                // 0. Apps / Formulae segmented toggle (+ manual Refresh).
                feedHeader

                if feedMode == .formulae {
                    formulaeFeed
                } else {
                appsFeed
                }
            }
            .padding(.vertical, 20)
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrolledID, anchor: .top)
        .onAppear {
            guard let anchor = scrollAnchor else { return }
            DispatchQueue.main.async { scrolledID = anchor }
        }
        .overlay {
            if feedMode == .apps && viewModel.isLoading {
                ProgressView()
            }
        }
        .task {
            await viewModel.load(db: appData.db)
        }
    }

    // Toggle row: segmented Apps/Formulae picker on the left. (The manual
    // refresh now lives beside the page title above, matching the other screens.)
    private var feedHeader: some View {
        HStack {
            feedModeToggle
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // True while a forced catalog refresh OR the feed-list rebuild is running.
    private var catalogRefreshing: Bool {
        isRefreshing || appData.isLoadingCasks || appData.isLoadingFormulae
    }

    // Forces a fresh catalog + analytics fetch (bypassing the 6-hour TTL),
    // then rebuilds the in-memory home feed from the refreshed DB.
    private func refreshHome() async {
        isRefreshing = true
        await appData.refreshCatalog(force: true)
        await viewModel.load(db: appData.db)
        isRefreshing = false
    }

    // Segmented Apps/Formulae picker.
    private var feedModeToggle: some View {
        Picker("", selection: $feedMode) {
            ForEach(HomeFeedMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)
    }

    // MARK: - Apps feed (original home content)
    @ViewBuilder
    private var appsFeed: some View {
        VStack(spacing: 24) {

                // 1. Category chip row
                categoryChipRow

                // 2. Featured hero card (if available)
                if let featured = viewModel.featuredCask {
                    FeaturedHeroCard(
                        cask: featured,
                        installed: appData.installedByToken[featured.token],
                        onLearnMore: {
                            onCaskTapped?(featured)
                        }
                    )
                    .padding(.horizontal, 20)
                }

                // 3. Two-column: Trending + Arrivals
                if !viewModel.isLoading {
                    twoColumnSection
                }

                // 4. Bottom grid: top 12 trending
                if !viewModel.trendingCasks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Trending Now", action: nil)
                        let gridColumns = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 12)]
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(viewModel.trendingCasks.prefix(12)) { cask in
                                AppCardView(
                                    cask: cask,
                                    installed: appData.installedByToken[cask.token],
                                    installCount: cask.installCount30d,
                                    onTap: { tapped in
                                        scrollAnchor = scrolledID ?? tapped.id
                                        onCaskTapped?(tapped)
                                    },
                                    onInstall: {
                                        // Shared manager (survives navigation;
                                        // the old discard never ran the install).
                                        appData.startInstall(
                                            token: $0.token,
                                            isUpgrade: appData.installedByToken[$0.token]?.isOutdated ?? false
                                        )
                                    }
                                )
                                .id(cask.id)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
        }
    }

    // MARK: - Formulae feed
    // Top formulae by install count, rendered as a card grid. Tapping a card
    // opens the formula detail page; install runs the brew formula install.
    @ViewBuilder
    private var formulaeFeed: some View {
        if appData.formulae.isEmpty {
            // Either still loading, or nothing loaded yet. Show a spinner while
            // loading; otherwise show an empty state with a manual reload, and
            // kick a load in case refreshAll() hasn't populated formulae yet
            // (e.g. the very first time the user opens the Formulae tab).
            VStack(spacing: 14) {
                if appData.isLoadingFormulae {
                    ProgressView()
                        .progressViewStyle(.forgedbrewLarge)
                    Text("Loading formulae…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No formulae loaded yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Button("Load Formulae") {
                        Task { await appData.refreshFormulas() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
            .task {
                // Self-heal: if formulae never loaded (or failed earlier),
                // attempt a load when this tab first appears.
                if appData.formulae.isEmpty && !appData.isLoadingFormulae {
                    await appData.refreshFormulas()
                }
            }
        } else if !showAllFormulae {
            // Default view: a ranked list of the most-downloaded formulae,
            // styled like the cask Trending list (numbered rows in a card).
            // Nobody scrolls the full ~8k catalog top-to-bottom, so we show the
            // top N and offer "Show All" to expand the full list inline.
            let ranked = appData.formulae
                .sorted { $0.installCount30d > $1.installCount30d }
                .prefix(formulaeRankedCount)
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Most Downloaded", action: nil)
                VStack(spacing: 0) {
                    ForEach(Array(ranked.enumerated()), id: \.element.id) { index, formula in
                        FormulaTrendingRow(rank: index + 1, formula: formula)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                            .onTapGesture { onFormulaTapped?(formula) }
                        if index < ranked.count - 1 { Divider().padding(.horizontal, 12) }
                    }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
                .padding(.horizontal, 20)

                Button {
                    showAllFormulae = true
                } label: {
                    Text("Show All Formulae (\(appData.formulae.count.formatted()))")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(OutlinedButtonStyle())
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        } else {
            // Expanded view: the full catalog A–Z, paged with "Load More".
            // The sidebar subcategories and search are the primary ways to find
            // a specific formula; this is the browse-everything fallback.
            let allFormulae = appData.formulae
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let visible = allFormulae.prefix(formulaeVisibleCount)
            let remaining = allFormulae.count - visible.count
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("All Formulae (\(allFormulae.count.formatted()))")
                        .font(.title3).fontWeight(.bold)
                    Spacer()
                    Button("Show Top Picks") {
                        showAllFormulae = false
                        formulaeVisibleCount = formulaePageSize
                    }
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                let gridColumns = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 12)]
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(Array(visible)) { formula in
                        FormulaCardView(
                            formula: formula,
                            installed: appData.installedByToken[formula.name],
                            onTap: { onFormulaTapped?($0) },
                            onInstall: {
                                // Shared manager (survives navigation; the old
                                // `_ = appData.installFormula(...)` discarded the
                                // stream so nothing ran).
                                appData.startInstall(
                                    token: $0.name,
                                    isUpgrade: appData.installedByToken[$0.name]?.isOutdated ?? false,
                                    isFormula: true
                                )
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)

                if remaining > 0 {
                    Button {
                        formulaeVisibleCount += formulaePageSize
                    } label: {
                        Text("Load More (\(remaining.formatted()) remaining)")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(OutlinedButtonStyle())
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var categoryChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" chip
                chipButton(label: "All", isSelected: selectedCategory == nil) {
                    selectedCategory = nil
                    onCategorySelected?(nil)
                }
                ForEach(CaskCategory.allCases, id: \.self) { cat in
                    chipButton(label: cat.displayName, isSelected: selectedCategory == cat) {
                        selectedCategory = cat
                        onCategorySelected?(cat)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }

    // Local chip button (avoids conflict with CategoryChip from BrowseView)
    private func chipButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.12)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private var twoColumnSection: some View {
        HStack(alignment: .top, spacing: 16) {

            // Left: Trending ranked list
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Currently Trending", action: { onShowSort?(.trending) })
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.trendingCasks.prefix(10).enumerated()), id: \.element.id) { index, cask in
                        TrendingRow(rank: index + 1, cask: cask, installCount: cask.installCount30d)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                scrollAnchor = scrolledID ?? cask.id
                                onCaskTapped?(cask)
                            }
                        if index < 9 { Divider().padding(.horizontal, 12) }
                    }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
            }
            .frame(maxWidth: .infinity)

            // Right: 3-Month Trend
            VStack(alignment: .leading, spacing: 16) {

                // 3-Month Trend
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "3-Month Trend", action: { onShowSort?(.recentlyUpdated) })
                    VStack(spacing: 0) {
                        let topPopular = Array(viewModel.allTimePopular.prefix(10))
                        ForEach(Array(topPopular.enumerated()), id: \.element.id) { index, cask in
                            TrendingRow(rank: index + 1, cask: cask, installCount: cask.installCount90d, periodLabel: "90d")
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    scrollAnchor = scrolledID ?? cask.id
                                    onCaskTapped?(cask)
                                }
                            if index < topPopular.count - 1 { Divider().padding(.horizontal, 12) }
                        }
                    }
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
    }
}
