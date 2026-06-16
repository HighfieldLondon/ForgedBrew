import SwiftUI

// MARK: - CategoryChip View
struct CategoryChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
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
}

// MARK: - InstallLogSheet View
//
// Friendly install progress sheet shown when installing an app from a Browse
// card. Shows our own plain-language phase (Downloading… / Installing… /
// Cleaning up… / Done) with a bright-green flowing progress bar — NOT raw brew
// terminal output — matching the Updates, Installed, and detail-card surfaces.
// It still takes the same `lines` binding the caller streams into; the raw log
// is used only to derive the phase and detect completion/failure, never shown.
struct InstallLogSheet: View {
    let caskName: String
    @Binding var lines: [String]
    @Binding var isPresented: Bool

    // True once the stream finished (the runner appends a "✅ Done" sentinel).
    private var isDone: Bool {
        lines.last?.hasPrefix("✅") == true || lines.last?.hasPrefix("❌") == true
    }

    // A brew "Error: …" line, if the install failed.
    private var failureMessage: String? {
        lines.last(where: { $0.localizedCaseInsensitiveContains("error:") })
    }

    // Current phase, derived from the latest brew ==> marker line. Falls back to
    // "Preparing…" until brew emits its first marker.
    private var phaseLabel: String {
        for line in lines.reversed() {
            if let phase = InstallProgress.phase(forLine: line) { return phase.statusLabel }
        }
        return "Preparing…"
    }

    private var phaseSymbol: String {
        for line in lines.reversed() {
            if let phase = InstallProgress.phase(forLine: line) { return phase.statusSymbol }
        }
        return "hourglass"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isDone
                     ? (failureMessage != nil ? "\(caskName) failed" : "\(caskName) is ready")
                     : "Installing \(caskName)")
                    .font(.headline)
                Spacer()
                Button("Close") { isPresented = false }
                    .disabled(!isDone)
            }

            // Live phase line + green flowing bar while the install runs.
            if !isDone {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                        Image(systemName: phaseSymbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(phaseLabel)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Spacer(minLength: 0)
                    }
                    GreenDashProgressBar()
                        .frame(height: 4)
                }
            } else if let failureMessage {
                // Red failure banner with the brew error.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 14))
                    Text(failureMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            } else {
                // Success state.
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))
                    Text("Installed successfully.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, height: 200)
    }
}

// MARK: - BrowseView
struct BrowseView: View {
    @Bindable var viewModel: BrowseViewModel
    @Environment(AppDataService.self) var appData
    // Called when a card is tapped; the parent presents the detail page.
    var onCaskTapped: ((CaskMetadata) -> Void)?

    // Install sheet state
    @State private var showInstallSheet = false
    @State private var installSheetCask: CaskMetadata? = nil
    @State private var installLog: [String] = []
    @State private var installTask: Task<Void, Never>? = nil

    // Live scroll position, tracked by .scrollPosition(id:). Kept in LOCAL state
    // (never written into the @Observable view model during layout — that was
    // the cause of the earlier _NSDetectedLayoutRecursion). It continuously
    // reflects the top-most visible card as the user scrolls. We mirror it into
    // the (persistent) view model only on tap, and seed it back from the model
    // on appear — so position survives the detail-page round-trip AND restores
    // correctly even when the target card is several lazy pages down.
    @State private var scrolledID: CaskMetadata.ID? = nil

    private let gridColumns = [
        GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {

            // Fixed header region — needs a solid opaque background so the
            // scrolling grid does not show through (was causing a ghosted
            // translucent bar across the top of the window).
            VStack(spacing: 0) {
                // Scope picker (tab bar)
                scopeTabBar

                // Category chips
                categoryChipRow

                Divider()
            }
            // Small top inset so the first interactive row (scope tabs /
            // category chips) clears the window toolbar without making the
            // header band feel tall.
            .padding(.top, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            // Main grid
            ZStack {
                if viewModel.isLoading {
                    // Uses the app-wide ForgedBrewSpinnerStyle (set in ForgedBrewApp)
                    // so no AppKit spinner host / layout-recursion warnings.
                    ProgressView()
                        .progressViewStyle(.forgedbrewLarge)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredCasks.isEmpty {
                    emptyState
                } else if viewModel.isSubGrouped {
                    subcategoryGrid
                } else {
                    flatGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                sortMenu
            }
        }
        .task {
            await viewModel.load(db: appData.db)
        }
        .sheet(isPresented: $showInstallSheet) {
            if let cask = installSheetCask {
                InstallLogSheet(
                    caskName: cask.displayName,
                    lines: $installLog,
                    isPresented: $showInstallSheet
                )
            }
        }
    }

    // Card builder shared by both the flat and sub-grouped grids. On tap it
    // records the card's id as the scroll anchor (the only moment we navigate
    // to a detail page), so returning can restore the prior scroll position.
    private func card(for cask: CaskMetadata) -> some View {
        AppCardView(
            cask: cask,
            installed: appData.installedByToken[cask.token],
            // Show the count for the period the list is sorted by (30d / 90d /
            // 1y) with a matching caption, so Trending, 3-Month Trend and Top
            // Past Year no longer all display the same 30-day number.
            installCount: viewModel.sortOrder.installCount(for: cask),
            periodLabel: viewModel.sortOrder.periodLabel,
            onTap: { tappedCask in
                // Persist the CURRENT scroll position (top-most visible card),
                // not the tapped card, so Back returns to exactly where the
                // user was. Fall back to the tapped card if the position
                // binding hasn't reported yet.
                viewModel.scrollAnchorID = scrolledID ?? tappedCask.id
                // Remember the section the tapped card lives in so the
                // sub-grouped restore can realize that section first.
                viewModel.scrollAnchorSubcategory = tappedCask.subcategory
                onCaskTapped?(tappedCask)
            },
            onInstall: { targetCask in
                startInstall(targetCask)
            }
        )
        .id(cask.id)
    }

    // Flat grid, capped to the current page. Used for "All", search results, and
    // the large/flat categories (Fonts, Other). A "Load More" button reveals the
    // next page so we never lay out thousands of cards at once.
    private var flatGrid: some View {
        // Uses .scrollPosition(id:) bound to LOCAL state (scrolledID), which
        // restores reliably even when the target card is several lazy pages
        // down (SwiftUI scrolls to it as the lazy grid realizes rows). The
        // earlier recursion came from binding scroll state to the @Observable
        // view model; binding to local @State avoids it.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(viewModel.flatVisibleCasks) { cask in
                        card(for: cask)
                    }
                }
                .padding(16)
                .scrollTargetLayout()

                if viewModel.canLoadMoreFlat {
                    Button {
                        viewModel.loadMoreFlat()
                    } label: {
                        Text("Load More (\(viewModel.filteredCasks.count - viewModel.flatVisibleCasks.count) remaining)")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(OutlinedButtonStyle())
                    .padding(.bottom, 16)
                }
            }
            // .scrollPosition keeps `scrolledID` tracking the top-most visible
            // card as the user scrolls (so a tap captures the exact position).
            // Restore, however, goes through the ScrollViewReader proxy below:
            // seeding scrolledID alone lands short when the target card is many
            // lazy pages down and not yet realized. scrollTo, retried until the
            // layout settles, drives the LazyVGrid to realize rows and land on
            // the exact card — the same robust path the sub-grouped grid uses.
            .scrollPosition(id: $scrolledID, anchor: .top)
            .hardScrollEdge(.top)
            .onAppear { restoreScrollPosition(using: proxy) }
        }
    }

    // Flat-grid restore. Ensures enough cards are paged in to contain the anchor,
    // then converges on it via the shared retrying scrollTo so it works for any
    // category, including large flat ones (Fonts, Other) and search results.
    private func restoreScrollPosition(using proxy: ScrollViewProxy) {
        guard let anchor = viewModel.scrollAnchorID else { return }
        // If the anchor lives beyond the current page, page in until it's
        // included so scrollTo has a realizable target.
        var guardCount = 0
        while viewModel.canLoadMoreFlat
            && !viewModel.flatVisibleCasks.contains(where: { $0.id == anchor })
            && guardCount < 50 {
            viewModel.loadMoreFlat()
            guardCount += 1
        }
        converge(proxy: proxy, sectionID: nil, cardID: anchor)
    }

    // Sub-grouped grid (a top-level category with no subcategory selected): a
    // section header per subcategory, each followed by its own grid of cards,
    // ordered largest-first by the view model. Unlike flatGrid, the cards here
    // are nested two levels deep (Section -> LazyVGrid) under PINNED section
    // headers, where .scrollPosition(id:) can't track them — so this uses a
    // ScrollViewReader + retrying proxy.scrollTo to restore the prior position
    // on return from a detail page.
    private var subcategoryGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                    ForEach(viewModel.subcategorySections) { section in
                        Section {
                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(section.casks) { cask in
                                    card(for: cask)
                                }
                            }
                            .padding(.horizontal, 16)
                        } header: {
                            HStack(spacing: 6) {
                                Text(section.title)
                                    .font(.system(size: 14, weight: .semibold))
                                Text("\(section.casks.count)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.bar)
                            .id("section-\(section.id)")
                        }
                    }
                }
                .padding(.vertical, 8)
                .scrollTargetLayout()
            }
            .hardScrollEdge(.top)
            .onAppear { restoreSubgroupedScrollPosition(using: proxy) }
        }
    }

    // ScrollViewReader-based restore for the sub-grouped grid. The target card
    // may be unrealized several lazy pages down (where a single scrollTo silently
    // no-ops), so we retry a handful of times to give the LazyVGrid a chance to
    // realize rows. Anchors on .top so Back lands where the user left off.
    private func restoreSubgroupedScrollPosition(using proxy: ScrollViewProxy) {
        guard let anchor = viewModel.scrollAnchorID else { return }
        let sectionID = viewModel.scrollAnchorSubcategory.map { "section-\($0)" }
        converge(proxy: proxy, sectionID: sectionID, cardID: anchor)
    }

    // Shared restore routine for BOTH grids. The target card may be unrealized
    // several lazy pages down, where a single scrollTo silently no-ops. We:
    //   1. (sub-grouped only) first jump to the card's pinned SECTION header,
    //      which is always realized, to bring the right region into view.
    //   2. Repeatedly scrollTo the exact card across animation frames, retrying
    //      until the position stabilizes (the card is realized and at rest) or a
    //      max attempt cap is reached — so it lands precisely regardless of how
    //      far down the card is or how big the category is.
    // Anchors on .top so Back returns to exactly where the user left off.
    private func converge(proxy: ScrollViewProxy, sectionID: String?, cardID: CaskMetadata.ID) {
        Task { @MainActor in
            // Phase 1: realize the region via the (always-present) section header.
            if let sectionID {
                for _ in 0..<5 {
                    withAnimation(.none) { proxy.scrollTo(sectionID, anchor: .top) }
                    try? await Task.sleep(nanoseconds: 40_000_000) // 40ms
                }
            }
            // Phase 2: converge on the exact card. Keep nudging until two
            // consecutive passes leave the realized layout unchanged (settled),
            // capped so we never loop forever if the card was filtered away.
            var stableCount = 0
            for _ in 0..<24 {
                withAnimation(.none) { proxy.scrollTo(cardID, anchor: .top) }
                try? await Task.sleep(nanoseconds: 40_000_000) // 40ms
                // Heuristic settle: once the top-most tracked card matches (or is
                // close to) the anchor, count it stable; two stable passes ends.
                if scrolledID == cardID {
                    stableCount += 1
                    if stableCount >= 2 { break }
                } else {
                    stableCount = 0
                }
            }
            // One final landing so we end exactly on the card even if tracking
            // lagged, then clear anchors so later re-layouts don't yank us again.
            withAnimation(.none) { proxy.scrollTo(cardID, anchor: .top) }
            viewModel.scrollAnchorID = nil
            viewModel.scrollAnchorSubcategory = nil
        }
    }

    // Scope tab bar. Hidden when only one scope exists (the catalog is
    // casks/apps only), since a lone tab adds no value.
    @ViewBuilder
    private var scopeTabBar: some View {
        if BrowseScope.allCases.count > 1 {
            HStack(spacing: 0) {
                ForEach(BrowseScope.allCases, id: \.self) { scope in
                    Button {
                        viewModel.selectedScope = scope
                    } label: {
                        VStack(spacing: 4) {
                            Text(scope.rawValue + (scope == .apps ? " (\(viewModel.filteredCasks.count))" : ""))
                                .font(.system(size: 13, weight: viewModel.selectedScope == scope ? .semibold : .regular))
                                .foregroundStyle(viewModel.selectedScope == scope ? .primary : .secondary)
                            Rectangle()
                                .fill(viewModel.selectedScope == scope ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    // Horizontal scroll row of category chips
    private var categoryChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryChip(label: "All", isSelected: viewModel.selectedCategory == nil) {
                    viewModel.selectedSubcategory = nil
                    viewModel.selectedCategory = nil
                }
                ForEach(CaskCategory.allCases, id: \.self) { cat in
                    CategoryChip(label: cat.displayName, isSelected: viewModel.selectedCategory == cat) {
                        viewModel.selectedSubcategory = nil
                        viewModel.selectedCategory = viewModel.selectedCategory == cat ? nil : cat
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No apps found")
                .font(.title3)
                .foregroundStyle(.secondary)
            if !viewModel.searchText.isEmpty {
                Text("Try a different search term")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sortMenu: some View {
        Menu {
            ForEach([SortOrder.alphabetical, .trending, .allTimePopular, .topPastYear], id: \.self) { order in
                Button {
                    viewModel.sortOrder = order
                } label: {
                    if viewModel.sortOrder == order {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private func startInstall(_ cask: CaskMetadata) {
        installSheetCask = cask
        installLog = []
        showInstallSheet = true
        installTask?.cancel()
        installTask = Task {
            let stream = appData.install(cask: cask.token)
            for await line in stream {
                await MainActor.run { installLog.append(line) }
            }
            await MainActor.run { installLog.append("✅ Done") }
        }
    }
}

// MARK: - Preview
#Preview {
    BrowseView(viewModel: BrowseViewModel())
        .environment(AppDataService.shared)
        .frame(width: 800, height: 600)
}
