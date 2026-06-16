import Foundation
import SwiftUI

enum BrowseScope: String, CaseIterable {
    case apps = "Apps & Casks"
}

enum SortOrder: String, CaseIterable {
    case trending = "Trending"
    case allTimePopular = "3-Month Trend"
    case topPastYear = "Top Past Year"
    case alphabetical = "Alphabetical"
    case mostInstalled = "Most Installed"

    // The install-count window that matches this sort, so list cards show the
    // SAME period they are ranked by instead of always showing the 30-day
    // count. This is what made the Trending / 3-Month / Past-Year lists all
    // display an identical number per app. Returns the cask field to read and
    // a short caption suffix; alphabetical defaults to the 30-day momentum
    // figure (the everyday popularity signal).
    func installCount(for cask: CaskMetadata) -> Int {
        switch self {
        case .allTimePopular: return cask.installCount90d
        case .topPastYear:    return cask.installCount365d
        case .trending, .mostInstalled, .alphabetical: return cask.installCount30d
        }
    }

    var periodLabel: String {
        switch self {
        case .allTimePopular: return "90d"
        case .topPastYear:    return "1y"
        case .trending, .mostInstalled, .alphabetical: return "30d"
        }
    }
}

@MainActor @Observable final class BrowseViewModel {
    var casks: [CaskMetadata] = []
    var filteredCasks: [CaskMetadata] = []
    var searchText: String = "" { didSet { scrollAnchorID = nil; scrollAnchorSubcategory = nil; scheduleSearch() } }
    var selectedCategory: CaskCategory? = nil { didSet { flatDisplayLimit = Self.flatPageSize; scrollAnchorID = nil; scrollAnchorSubcategory = nil; applyFilters() } }
    // Optional subcategory filter within selectedCategory (set when the user
    // picks a sidebar disclosure child). nil means "all subcategories".
    var selectedSubcategory: String? = nil { didSet { scrollAnchorID = nil; scrollAnchorSubcategory = nil; applyFilters() } }
    var selectedScope: BrowseScope = .apps { didSet { applyFilters() } }
    var sortOrder: SortOrder = .alphabetical { didSet { scrollAnchorID = nil; scrollAnchorSubcategory = nil; applyFilters() } }
    var isLoading: Bool = false
    var showFOSSOnly: Bool = false { didSet { scrollAnchorID = nil; scrollAnchorSubcategory = nil; applyFilters() } }
    var showCommercialOnly: Bool = false { didSet { scrollAnchorID = nil; scrollAnchorSubcategory = nil; applyFilters() } }

    // Scoped search: when the user runs a search while browsing inside a
    // category (or subcategory), the search is constrained to that scope rather
    // than spanning the whole catalog. Set by the search VM before a query runs;
    // nil means "search everything". These are deliberately NOT the same as
    // selectedCategory/selectedSubcategory (which drive the browse grid) so the
    // search VM and the browse VM stay independent.
    var scopeCategory: CaskCategory? = nil
    var scopeSubcategory: String? = nil

    // Pagination for the flat (non-sub-grouped) grid — chiefly Fonts, which has
    // thousands of entries. We render at most `flatDisplayLimit` cards and reveal
    // more in pages, so the grid never tries to lay out the entire catalog at
    // once. Reset to one page whenever the category changes.
    static let flatPageSize: Int = 120
    var flatDisplayLimit: Int = BrowseViewModel.flatPageSize

    // The id of the top-most visible card, tracked via .scrollPosition in
    // BrowseView. Because this view model is shared across the catalog and
    // persists while the detail page is shown, restoring it on return brings
    // the grid back to where the user left off (fixes "Back jumps to top").
    // Cleared whenever the filter/sort/category changes so a new result set
    // always starts at the top.
    var scrollAnchorID: CaskMetadata.ID? = nil

    // The subcategory (section) the anchored card belongs to, in the sub-grouped
    // grid. Pinned section headers make .scrollPosition(id:) unreliable, so on
    // return we first scroll to this SECTION to force its lazy content to
    // realize, then converge on the exact card — fixing "Back jumps to a random
    // subcategory / the top". Cleared alongside scrollAnchorID.
    var scrollAnchorSubcategory: String? = nil

    private var searchTask: Task<Void, Never>? = nil
    private var db: DatabaseManager? = nil

    // The full catalog, used for in-memory scoped search. A global DB FTS query
    // is capped at 50 rows, which is fine for an unscoped search but would
    // starve a category-scoped search (few of the global top-50 fall in any one
    // category). When a scope is active we filter this full list instead.
    private var fullCatalog: [CaskMetadata] = []

    // Categories that are NOT sub-grouped in the browse grid. Fonts is huge and
    // gets a flat (paginated) grid; Other is a catch-all with no meaningful
    // subcategories. Everything else renders section headers per subcategory.
    private static let flatCategories: Set<CaskCategory> = [.fonts, .other]

    // A subcategory section: a display header plus its casks (already sorted by
    // the active sortOrder, inherited from filteredCasks).
    struct SubcategorySection: Identifiable {
        let id: String        // subcategory display name
        let title: String
        let casks: [CaskMetadata]
    }

    // True when the current view should render subcategory section headers:
    // exactly one category is selected, it supports sub-grouping, and there's
    // no active text search (search results span categories, so flat is clearer).
    var isSubGrouped: Bool {
        guard let category = selectedCategory else { return false }
        guard !Self.flatCategories.contains(category) else { return false }
        // When a single subcategory is already selected there's nothing to group
        // by — render the flat grid for that one subcategory.
        guard selectedSubcategory == nil else { return false }
        return searchText.isEmpty
    }

    // The slice of filteredCasks to show in the flat grid, capped at
    // flatDisplayLimit. Used only when isSubGrouped is false.
    var flatVisibleCasks: [CaskMetadata] {
        Array(filteredCasks.prefix(flatDisplayLimit))
    }

    // True when more flat-grid cards remain beyond the current page.
    var canLoadMoreFlat: Bool {
        flatDisplayLimit < filteredCasks.count
    }

    // Reveals one more page of flat-grid cards.
    func loadMoreFlat() {
        flatDisplayLimit += Self.flatPageSize
    }

    // filteredCasks grouped into subcategory sections, preserving the order in
    // filteredCasks within each section. Sections are ordered by descending
    // size (largest subcategory first) so the densest groups lead.
    var subcategorySections: [SubcategorySection] {
        var order: [String] = []
        var buckets: [String: [CaskMetadata]] = [:]
        for cask in filteredCasks {
            let sub = cask.subcategory
            if buckets[sub] == nil {
                buckets[sub] = []
                order.append(sub)
            }
            buckets[sub]?.append(cask)
        }
        return order
            .map { SubcategorySection(id: $0, title: $0, casks: buckets[$0] ?? []) }
            .sorted { $0.casks.count > $1.casks.count }
    }

    init() {}

    // Loads all casks from DB (fallback empty on error). Sets isLoading, updates self.casks, calls applyFilters().
    func load(db: DatabaseManager) async {
        self.db = db
        isLoading = true
        do {
            var fetchedCasks = try await db.fetchAllCasks()
            // Stamp any previously-resolved GitHub SPDX licenses onto the casks
            // so cards can show a real license badge without re-fetching. Only
            // the ~11% of casks visited on a detail page (with a GitHub repo)
            // will have an entry; the rest stay nil ("license unknown").
            if let licenses = try? await db.fetchAllCaskGitHubLicenses(), !licenses.isEmpty {
                for i in fetchedCasks.indices {
                    if let lic = licenses[fetchedCasks[i].token] {
                        fetchedCasks[i].cachedLicense = lic
                    }
                }
            }
            casks = fetchedCasks
            fullCatalog = fetchedCasks
        } catch {
            casks = []
        }
        applyFilters()
        isLoading = false
    }

    // Seeds the in-memory full catalog without disturbing the displayed results.
    // Used by the search VM (which doesn't render the browse grid) so scoped
    // search can filter the complete catalog handed down from AppDataService.
    func seedCatalog(_ all: [CaskMetadata]) {
        fullCatalog = all
    }

    // Forces the browse grid to re-render from the current catalog: resets the
    // flat-grid pagination to the first page and re-runs the in-memory
    // filter/sort. Deliberately does NOT touch scrollAnchorID — it is only
    // called on a genuine sidebar transition (or when the displayed list is
    // empty while the catalog is loaded), never on a Back re-appear, so scroll
    // restoration is unaffected. Pure in-memory work: no DB or network.
    func refreshDisplayedList() {
        flatDisplayLimit = Self.flatPageSize
        applyFilters()
    }

    // Filters self.casks → self.filteredCasks.
    func applyFilters() {
        var result = casks

        // 0. Scoped-search constraint. When a search is scoped to a category
        //    (and optionally a subcategory), narrow to it first so the text
        //    match below only ever returns in-scope results.
        if let scope = scopeCategory {
            result = result.filter { $0.category == scope }
            if let scopeSub = scopeSubcategory {
                result = result.filter { $0.subcategory == scopeSub }
            }
        }

        // 1. selectedCategory match
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }

        // 1b. selectedSubcategory match (only meaningful with a category set)
        if let sub = selectedSubcategory {
            result = result.filter { $0.subcategory == sub }
        }

        // 2. Open Source filter. "Open source" = the cask is hosted on GitHub
        //    (a strong open-source signal) OR we resolved a real OSS SPDX
        //    license from GitHub. The Homebrew cask API carries no license, so
        //    this is the most honest definition we can offer.
        if showFOSSOnly {
            result = result.filter { $0.isLikelyOpenSource }
        }

        // 3. "Other" filter — the complement: casks with no open-source signal
        //    (no GitHub repo and no known OSS license). We deliberately do NOT
        //    label these "commercial": we can't prove that. They are simply
        //    apps whose license we can't determine.
        if showCommercialOnly {
            result = result.filter { !$0.isLikelyOpenSource }
        }

        // 4. searchText: keep displayName/token/desc lowercased contains
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { cask in
                cask.displayName.lowercased().contains(query) ||
                cask.token.lowercased().contains(query) ||
                (cask.desc ?? "").lowercased().contains(query)
            }
        }

        // 5. selectedScope: only .apps exists (the catalog holds casks/apps).
        switch selectedScope {
        case .apps:
            break
        }

        // 6. Sort
        switch sortOrder {
        case .trending:
            // Trending = most-installed over the last 30 days (recent momentum).
            result.sort { $0.installCount30d > $1.installCount30d }
        case .mostInstalled:
            result.sort { $0.installCount30d > $1.installCount30d }
        case .allTimePopular:
            // 3-Month Trend = most-installed over the last 90 days (sustained
            // popularity). Distinct from 30d trending momentum.
            result.sort { $0.installCount90d > $1.installCount90d }
        case .topPastYear:
            // Top Past Year = most-installed over the last 365 days. The
            // longest-window popularity signal Homebrew analytics expose.
            result.sort { $0.installCount365d > $1.installCount365d }
        case .alphabetical:
            result.sort { cask1, cask2 in
                cask1.displayName.localizedCaseInsensitiveCompare(cask2.displayName) == .orderedAscending
            }
        }

        filteredCasks = result
    }

    // Debounced search. Cancels previous task, waits 300ms, then local filter or DB search.
    //
    // Two modes:
    //  - UNSCOPED (scopeCategory == nil): query the DB FTS index (fast, but
    //    capped at 50 rows) and use those as the working set.
    //  - SCOPED (scopeCategory != nil): search the full in-memory catalog so we
    //    don't lose in-category matches to the global LIMIT 50. applyFilters()
    //    then narrows by scope + text.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }

                if self.searchText.count < 2 {
                    self.applyFilters()
                } else if self.scopeCategory != nil {
                    // Scoped: filter the full catalog (applyFilters handles the
                    // scope + text matching below).
                    self.casks = self.fullCatalog
                    self.applyFilters()
                } else if let db = self.db {
                    let results = try await db.searchCasks(query: self.searchText)
                    self.casks = results
                    self.applyFilters()
                } else {
                    self.applyFilters()
                }
            } catch {
                if !Task.isCancelled {
                    self.applyFilters()
                }
            }
        }
    }

    // Same as scheduleSearch but external + takes db param. Setting searchText triggers scheduleSearch via didSet.
    func search(query: String, db: DatabaseManager) async {
        self.db = db
        self.searchText = query
    }
}
