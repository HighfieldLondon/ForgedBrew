import SwiftUI

// MARK: - FormulaCardView
// Compact grid card for a single formula (CLI package). Mirrors AppCardView but
// is simpler: formulae have no local .app icon, so we always show a generated
// monospace-style placeholder, plus name / description / install count / button.
struct FormulaCardView: View {
    let formula: FormulaMetadata
    let installed: InstalledPackage?
    let onTap: (FormulaMetadata) -> Void
    let onInstall: (FormulaMetadata) -> Void

    @State private var isHovered: Bool = false

    private var buttonState: InstallButtonState {
        guard let pkg = installed else { return .get }
        return pkg.isOutdated ? .update : .installed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Top: terminal glyph badge + license-style badge
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.green.gradient)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Spacer()
                Text(formula.githubURL != nil ? "OSS" : "CLI")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(formula.githubURL != nil ? .green : .blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        (formula.githubURL != nil ? Color.green : Color.blue).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
            .padding(.bottom, 10)

            // Name (formula name is already the token / CLI command)
            Text(formula.name)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.bottom, 4)

            // Description
            Text(formula.desc ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Status: only surfaced when the formula is Disabled (red, the
            // strongest signal — installing will fail) or Deprecated (amber,
            // on its way out). Healthy formulae show no pill so the card stays
            // clean. Mirrors the Status box on the detail card.
            if formula.disabled {
                CardMetaPill(systemImage: "xmark.octagon", text: "Disabled", color: .red)
                    .padding(.top, 6)
            } else if formula.deprecated {
                CardMetaPill(systemImage: "exclamationmark.triangle", text: "Deprecated", color: .orange)
                    .padding(.top, 6)
            }

            Spacer(minLength: 8)

            // Bottom row: install count + button
            HStack(alignment: .bottom) {
                if formula.installCount30d > 0 {
                    Text("\(formula.installCount30d.formatted()) installs")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                InstallButton(state: buttonState) {
                    // "Get" (not-installed) opens the detail page so the user can
                    // review everything and choose to install from there — it no
                    // longer fires an install command directly. "Update" still
                    // kicks off the upgrade in place.
                    switch buttonState {
                    case .get:
                        onTap(formula)
                    case .update:
                        onInstall(formula)
                    case .installed:
                        break
                    }
                }
            }
        }
        .padding(14)
        .frame(minHeight: 150)
        .background {
            RoundedRectangle(cornerRadius: 13)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
                .shadow(
                    color: .black.opacity(isHovered ? 0.12 : 0.04),
                    radius: isHovered ? 8 : 3,
                    y: isHovered ? 2 : 1
                )
        }
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in isHovered = hovering }
        .onTapGesture { onTap(formula) }
        .contentShape(RoundedRectangle(cornerRadius: 13))
    }
}

// MARK: - FormulaSortOrder
// Sort options for the formulae browse grids, surfaced via a toolbar menu that
// sits next to the search bar (mirroring the cask BrowseView sort menu).
// Popularity (30-day install count) is the default; Alphabetical is by name.
enum FormulaSortOrder: String, CaseIterable, Hashable {
    case popularity = "Popularity"
    case alphabetical = "Alphabetical"
}

// MARK: - FormulaBrowseView
// Browse grid for formulae. Renders either a single subcategory (when
// `subcategory` is non-nil — driven by a sidebar subcategory row) or a
// sub-grouped view of every subcategory (when nil — the "Formulae" root row).
// Reads the full catalog from appData.formulae and classifies on the fly via
// FormulaClassifier, mirroring how casks are grouped in BrowseView.
struct FormulaBrowseView: View {
    // nil -> show all formulae grouped by subcategory; non-nil -> only that one.
    let subcategory: String?
    let onFormulaTapped: (FormulaMetadata) -> Void

    @Environment(AppDataService.self) var appData

    // Install sheet state (reuses the cask InstallLogSheet UI).
    @State private var showInstallSheet = false
    @State private var installSheetFormula: FormulaMetadata? = nil
    @State private var installLog: [String] = []
    @State private var installTask: Task<Void, Never>? = nil

    @State private var scrolledID: FormulaMetadata.ID? = nil

    // Default sort is Popularity (most-installed first); persists per launch.
    @State private var sortOrder: FormulaSortOrder = .popularity

    // CACHED, precomputed view data. Previously `matching`/`sections` were
    // computed properties that re-filtered, re-sorted and re-grouped all ~8,400
    // formulae on EVERY SwiftUI body evaluation (i.e. every scroll frame), each
    // touch also re-running the expensive classifier — which made scrolling
    // crawl, especially after visiting a few subcategories. Now we compute them
    // once into @State and only recompute when the real inputs change (the
    // loaded catalog, the chosen subcategory, or the sort order).
    @State private var matching: [FormulaMetadata] = []
    @State private var sections: [(title: String, formulae: [FormulaMetadata])] = []
    // True once recomputeViewData has run at least once, so we do not flash the
    // "No formulae found" empty state in the one frame before the cache fills.
    @State private var didComputeViewData = false

    private let gridColumns = [
        GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 12)
    ]

    // Subcategory for a formula, read from the precomputed cache on
    // AppDataService (classified once at load) rather than re-classifying on
    // every access. Falls back to a live classify only if the cache is somehow
    // cold (e.g. a formula that arrived outside the normal load path).
    private func sub(for formula: FormulaMetadata) -> String {
        appData.formulaSubcategoryByToken[formula.name]
            ?? FormulaClassifier.classify(name: formula.name, desc: formula.desc, homepage: formula.homepage)
    }

    // Recompute the cached `matching` + `sections` from the current inputs. Runs
    // off the body, only when inputs actually change, so scrolling stays cheap.
    private func recomputeViewData() {
        // 1. Filter to the active subcategory (or all) using the cached lookup.
        let base: [FormulaMetadata]
        if let activeSub = subcategory {
            base = appData.formulae.filter { sub(for: $0) == activeSub }
        } else {
            base = appData.formulae
        }
        // 2. Sort.
        let sorted: [FormulaMetadata]
        switch sortOrder {
        case .popularity:
            sorted = base.sorted {
                if $0.installCount30d != $1.installCount30d {
                    return $0.installCount30d > $1.installCount30d
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .alphabetical:
            sorted = base.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        matching = sorted

        // 3. Group into sections (only needed for the root grouped grid).
        if subcategory == nil {
            let grouped = Dictionary(grouping: sorted) { sub(for: $0) }
            let canonicalIndex = Dictionary(
                uniqueKeysWithValues: FormulaClassifier.subcategories().enumerated().map { ($1, $0) }
            )
            let undefined = FormulaClassifier.undefinedSubcategory
            sections = grouped
                .filter { !$0.value.isEmpty }
                .sorted { lhs, rhs in
                    // "Undefined" always sorts last regardless of size.
                    let lUndef = (lhs.key == undefined)
                    let rUndef = (rhs.key == undefined)
                    if lUndef != rUndef { return rUndef }
                    if lhs.value.count != rhs.value.count {
                        return lhs.value.count > rhs.value.count
                    }
                    let li = canonicalIndex[lhs.key] ?? Int.max
                    let ri = canonicalIndex[rhs.key] ?? Int.max
                    if li != ri { return li < ri }
                    return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                }
                .map { (title: $0.key, formulae: $0.value) }
        } else {
            sections = []
        }
        didComputeViewData = true
    }

    // Identity for the recompute task: changes only when a real input changes
    // (catalog size after load, selected subcategory, or sort order). Scrolling
    // does not change this, so recompute does not run on scroll.
    private var recomputeKey: String {
        "\(appData.formulae.count)|\(subcategory ?? "*")|\(sortOrder.rawValue)"
    }

    var body: some View {
        ZStack {
            if (appData.isLoadingFormulae && appData.formulae.isEmpty) || !didComputeViewData {
                ProgressView()
                    .progressViewStyle(.forgedbrewLarge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matching.isEmpty {
                emptyState
            } else if subcategory == nil {
                groupedGrid
            } else {
                flatGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Recompute the cached grid data when the view first appears and whenever
        // a real input changes — never on a plain scroll-driven body eval.
        .task(id: recomputeKey) { recomputeViewData() }
        .sheet(isPresented: $showInstallSheet) {
            if let formula = installSheetFormula {
                InstallLogSheet(
                    caskName: formula.name,
                    lines: $installLog,
                    isPresented: $showInstallSheet
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                sortMenu
            }
        }
    }

    // Sort menu shown in the toolbar, beside the search bar. Mirrors the cask
    // BrowseView sort menu so both browse experiences feel consistent.
    private var sortMenu: some View {
        Menu {
            ForEach(FormulaSortOrder.allCases, id: \.self) { order in
                Button {
                    sortOrder = order
                } label: {
                    if sortOrder == order {
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

    private func card(for formula: FormulaMetadata) -> some View {
        FormulaCardView(
            formula: formula,
            installed: appData.installedByToken[formula.name],
            onTap: { tapped in
                // Capture the scroll position BEFORE navigating so returning from
                // the detail card lands back here. Prefer the live top-most card
                // (scrolledID); fall back to the tapped card if tracking is cold.
                appData.formulaScrollAnchorID = scrolledID ?? tapped.id
                appData.formulaScrollAnchorSubcategory = sub(for: tapped)
                onFormulaTapped(tapped)
            },
            onInstall: { startInstall($0) }
        )
        .id(formula.id)
    }

    // Single-subcategory flat grid. Renders all `matching` cards in one
    // LazyVGrid (no paging). Wrapped in a ScrollViewReader so we can restore the
    // prior scroll position when returning from a detail card.
    private var flatGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(matching) { formula in
                        card(for: formula)
                    }
                }
                .padding(16)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrolledID, anchor: .top)
            .hardScrollEdge(.top)
            .onAppear { restoreScrollPosition(using: proxy) }
        }
    }

    // Root view: a pinned section header per subcategory, each with its own grid.
    // Wrapped in a ScrollViewReader and each header carries an .id so we can jump
    // back to the right section + card on return from a detail card.
    private var groupedGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(section.formulae) { formula in
                                    card(for: formula)
                                }
                            }
                            .padding(.horizontal, 16)
                        } header: {
                            HStack(spacing: 6) {
                                Text(section.title)
                                    .font(.system(size: 14, weight: .semibold))
                                Text("\(section.formulae.count)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.bar)
                            .id("section-\(section.title)")
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .hardScrollEdge(.top)
            .onAppear { restoreSubgroupedScrollPosition(using: proxy) }
        }
    }

    // Flat-grid restore: the grid renders every card at once, so we just converge
    // on the saved anchor card.
    private func restoreScrollPosition(using proxy: ScrollViewProxy) {
        guard let anchor = appData.formulaScrollAnchorID else { return }
        converge(proxy: proxy, sectionID: nil, cardID: anchor)
    }

    // Sub-grouped restore: jump to the saved section header first (always
    // realized), then converge on the exact card.
    private func restoreSubgroupedScrollPosition(using proxy: ScrollViewProxy) {
        guard let anchor = appData.formulaScrollAnchorID else { return }
        let sectionID = appData.formulaScrollAnchorSubcategory.map { "section-\($0)" }
        converge(proxy: proxy, sectionID: sectionID, cardID: anchor)
    }

    // Shared restore routine for both grids (mirrors the cask BrowseView). The
    // target card may be unrealized far down a LazyVGrid, where a single
    // scrollTo silently no-ops, so we retry across animation frames until the
    // position settles, then clear the anchors so later re-layouts do not yank.
    private func converge(proxy: ScrollViewProxy, sectionID: String?, cardID: FormulaMetadata.ID) {
        Task { @MainActor in
            // Phase 1: realize the region via the (always-present) section header.
            if let sectionID {
                for _ in 0..<5 {
                    withAnimation(.none) { proxy.scrollTo(sectionID, anchor: .top) }
                    try? await Task.sleep(nanoseconds: 40_000_000) // 40ms
                }
            }
            // Phase 2: converge on the exact card until two stable passes.
            var stableCount = 0
            for _ in 0..<24 {
                withAnimation(.none) { proxy.scrollTo(cardID, anchor: .top) }
                try? await Task.sleep(nanoseconds: 40_000_000) // 40ms
                if scrolledID == cardID {
                    stableCount += 1
                    if stableCount >= 2 { break }
                } else {
                    stableCount = 0
                }
            }
            withAnimation(.none) { proxy.scrollTo(cardID, anchor: .top) }
            appData.formulaScrollAnchorID = nil
            appData.formulaScrollAnchorSubcategory = nil
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No formulae found")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startInstall(_ formula: FormulaMetadata) {
        installSheetFormula = formula
        installLog = []
        showInstallSheet = true
        installTask?.cancel()
        installTask = Task {
            let stream = appData.installFormula(formula.name)
            for await line in stream {
                await MainActor.run { installLog.append(line) }
            }
            await MainActor.run { installLog.append("✅ Done") }
        }
    }
}
