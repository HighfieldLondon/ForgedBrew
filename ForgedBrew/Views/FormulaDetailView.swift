import SwiftUI
import AppKit

// MARK: - FormulaDetailView
// Detail page for a single formula (CLI package). This mirrors the cask
// DetailView layout exactly: a header (glyph + name + favorite + badges + desc),
// the shared action-button row (Install / Homepage / Homebrew Page / GitHub Page
// / Copy Command / Uninstall), a five-card stat row, and a tabbed content area
// (Overview / Screenshots / Dependencies / About) beside an info sidebar.
//
// Formulae use a different model (FormulaMetadata) and a different install path
// (AppDataService.installFormula / uninstallFormula / upgradeFormula streamed
// into an inline phase HUD) than casks, so this view keeps its own @State rather
// than the cask DetailViewModel — but it reuses every shared sub-view
// (DetailActionButton, StatCard, ReadmeView, ScreenshotsView, DependenciesView,
// AboutView, TagSection, FavoriteButton) so the two cards look identical.
struct FormulaDetailView: View {
    let formula: FormulaMetadata
    let onBack: () -> Void

    @Environment(AppDataService.self) var appData

    // Drives the "Add to favorites" hint beside the header star, mirroring the
    // hover behavior on the summary card.
    @State private var isHeaderHovered = false
    // Drives the back button hover highlight.
    @State private var isBackHovered = false
    // Shows a transient "Copied!" confirmation on the Copy Command button.
    @State private var didCopyCommand = false

    // Which tab is selected in the content area. Same enum the cask card uses,
    // so the segmented strip reads identically (Overview / Screenshots /
    // Dependencies / About).
    @State private var selectedTab: DetailTab = .overview

    // NOTE: install/uninstall no longer runs inline in this view. The action
    // buttons call the SHARED install manager (appData.startInstall /
    // startUninstall), exactly like the cask detail card. Progress is observed
    // via appData.installProgress[formula.name] and rendered by the single
    // centered app-root HUD; busy state comes from appData.isOperationInFlight.
    // This removed the per-line view-local state churn (actionLog / isWorking /
    // actionSucceeded / actionTask) that re-rendered the card on every brew
    // output line and made the whole window jump during an operation.

    // Richer detail lazily fetched from the single-formula API endpoint. The
    // catalog cache (formulas table) only stores lightweight fields, so
    // dependencies and the HEAD version arrive empty there. When this is
    // populated we prefer it; until then we show what the catalog gave us.
    @State private var enriched: FormulaMetadata? = nil
    // True while the lazy detail fetch is in flight, so the dependencies area
    // can show a subtle loading hint instead of appearing to have none.
    @State private var isLoadingDetail = false

    // Bottle download size (bytes) for THIS Mac's platform, fetched over the
    // network on open ONLY for formulae that are NOT installed. Installed
    // formulae show their real on-disk Cellar size instead, so this stays nil
    // for them. This is the compressed bottle artifact size from ghcr.io.
    @State private var bottleSizeBytes: Int64? = nil

    // The date this formula's .rb file was last committed in
    // Homebrew/homebrew-core — the real "last updated in the catalog" date.
    // Resolved lazily from GitHub on open and disk-cached. nil until resolved.
    @State private var catalogLastUpdated: Date? = nil

    // ---- About / Overview / repo resolution (mirrors the cask card) ----
    // The source repo for this formula. Prefer a github.com homepage; otherwise
    // best-effort host-matched search (cached, rate-limited). Drives the GitHub
    // Page button, the README fetch, and the About panel's "Source" row.
    @State private var resolvedRepoURL: URL? = nil
    @State private var repoResolved = false
    // The fetched README markdown (Overview + About tabs) and its load flag.
    @State private var readme: String? = nil
    @State private var readmeLoading = false
    @State private var readmeAttempted = false
    // The resolved SPDX license id from GitHub (preferred over the catalog one).
    @State private var githubLicense: String? = nil
    // The Wikipedia summary blurb used by the About tab when there's no README.
    @State private var aboutWebBlurb: String? = nil
    @State private var aboutWebBlurbLoading = false
    @State private var aboutWebBlurbAttempted = false
    // Homepage HTML metadata (title / meta or OG description / og:image),
    // fetched once. Enriches Overview + More Info for tools with a rich homepage
    // but no Wikipedia article or README, and offers its og:image to the gallery.
    @State private var homepageMeta: BrewAPIService.HomepageMeta? = nil
    @State private var homepageMetaAttempted = false
    // A "project wiki" blurb (GitHub repo wiki Home), a secondary source when
    // Wikipedia has no article but the project keeps its own wiki.
    @State private var projectWikiBlurb: String? = nil
    @State private var projectWikiAttempted = false
    // FULL Wikipedia article (Markdown w/ section headings) for the More Info
    // long-form panel when there's no README — the whole page of detail.
    @State private var aboutFullArticle: String? = nil
    @State private var aboutFullArticleAttempted = false
    // Set true once the lazy loaders finish their whole pass, so the
    // resolving flags stop spinning even when later fetches are skipped
    // (e.g. the full article is skipped when a README is present).
    @State private var aboutResolveCompleted = false
    @State private var overviewResolveCompleted = false

    // ---- Screenshots (homepage-preview fallback) ----
    // Formulae publish no real screenshots, but most have a homepage. We render
    // a snapshot of that page (or, last resort, the formulae.brew.sh page) so
    // the Screenshots tab shows something representative instead of only text.
    @State private var screenshotURLs: [URL] = []
    @State private var screenshotsLoading = false
    @State private var screenshotsResolved = false
    // True when the shots shown are a rendered page snapshot, not real
    // screenshots, so the tab can caption them "Homepage preview".
    @State private var screenshotsAreHomepagePreview = false

    // ---- My Note (matches the cask detail card exactly) ----
    @State private var note: String = ""
    @State private var noteJustSaved = false

    // The formula we actually render: the enriched copy when available,
    // otherwise the catalog one passed in.
    private var displayFormula: FormulaMetadata { enriched ?? formula }

    // The HEAD version string, if this formula supports a HEAD build. Only the
    // single-formula endpoint carries this, so it appears after enrichment.
    private var headVersion: String? {
        guard let head = displayFormula.versions.head, !head.isEmpty else { return nil }
        return head
    }

    private var installed: InstalledPackage? {
        appData.installedByToken[formula.name]
    }

    private var isInstalled: Bool { installed != nil }
    private var isOutdated: Bool { installed?.isOutdated ?? false }

    // A coarse snapshot of THIS formula's in-flight operation phase, so .onChange
    // can react the instant an install/uninstall finishes and refresh the shared
    // installed set — flipping Install↔Installed (and showing/hiding the Uninstall
    // button) right away. IDENTICAL to the cask card's progressPhaseKey. The
    // shared install manager's finish() only sets the phase; it does NOT itself
    // call refreshInstalled, so the card drives that here (same as the cask).
    private var progressPhaseKey: String {
        guard let p = appData.installProgress[formula.name] else { return "none" }
        switch p.phase {
        case .finished: return "finished"
        case .failed:   return "failed"
        default:        return "active"
        }
    }

    // The repo URL to link/use: the lazily-resolved one, else the homepage if it
    // already points at github.com.
    private var repoURL: URL? { resolvedRepoURL ?? formula.githubURL }

    // SHORT Overview summary (a glance); the full long-form lives in More Info.
    // We use only the README *intro* here, never the whole README, so Overview
    // and More Info don't render identical content for README-only packages.
    //
    // The Homebrew description leads because it is a CURATED, package-specific
    // one-liner. The Wikipedia blurb is demoted to LAST: it is generic or, for
    // name-collisions, the wrong entity — the long encyclopedic text belongs in
    // More Info, not at the top of Overview. New order:
    //   1. Homebrew description  2. Homepage description  3. README intro
    //   4. Project-wiki blurb    5. Wikipedia blurb (last resort)
    private var overviewText: String? {
        let d = formula.desc?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d, !d.isEmpty { return d }
        let homeDesc = homepageMeta?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let homeDesc, !homeDesc.isEmpty { return homeDesc }
        if let md = readme?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty,
           let intro = DetailViewModel.readmeIntro(from: md), !intro.isEmpty { return intro }
        let wiki = projectWikiBlurb?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wiki, !wiki.isEmpty { return wiki }
        let blurb = aboutWebBlurb?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (blurb?.isEmpty == false) ? blurb : nil
    }

    // The long-form content the More Info tab renders (full page of detail), in
    // order: full README -> full Wikipedia article -> project-wiki blurb.
    // Which source supplied the More Info long-form content (drives the footer
    // "View this …" link).
    private enum AboutLongFormSource { case readme, homepage, wikipedia, projectWiki }

    // Long-form More Info content in descending identity confidence:
    //   1. README  2. Homepage text  3. Wikipedia  4. project wiki.
    // Homepage is promoted ABOVE Wikipedia because Wikipedia name-collisions
    // (e.g. simdjson -> "The Simpsons", bison -> the animal) are the main
    // source of wrong cards; the project's own site never collides.
    private var aboutLongForm: String? {
        if let md = readme?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty { return md }
        if let home = homepageMeta?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty { return home }
        if let art = aboutFullArticle?.trimmingCharacters(in: .whitespacesAndNewlines), !art.isEmpty { return art }
        if let w = projectWikiBlurb?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty { return w }
        return nil
    }

    // The source backing aboutLongForm (same priority order).
    private var aboutLongFormSource: AboutLongFormSource {
        if !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return .readme }
        if !((homepageMeta?.description)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return .homepage }
        if !(aboutFullArticle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return .wikipedia }
        return .projectWiki
    }

    // Whether the long-form is the README — retained for README-vs-not callers.
    private var aboutLongFormIsReadme: Bool {
        aboutLongFormSource == .readme
    }

    // True while the Overview's preferred source (Wikipedia blurb) is still
    // resolving and we don't yet have it — drives the Overview "Loading…" note.
    private var overviewResolving: Bool {
        let haveText = !(overviewText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if haveText { return false }
        if overviewResolveCompleted { return false }
        return aboutWebBlurbLoading || readmeLoading || !overviewResolveCompleted
    }

    // True when Overview already shows SOMETHING (usually the short Homebrew
    // description) but a richer source (README / Wikipedia blurb / project-wiki
    // / homepage meta) is still being fetched — drives the subtle inline
    // "Loading fuller description…" hint.
    private var overviewUpgrading: Bool {
        if overviewResolveCompleted { return false }
        let haveRich = !(aboutWebBlurb?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(projectWikiBlurb?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !((homepageMeta?.description)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if haveRich { return false }
        let haveDesc = !(formula.desc?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return haveDesc && (aboutWebBlurbLoading || readmeLoading || !overviewResolveCompleted)
    }

    // True while the More Info long-form is still resolving and we don't yet
    // have it — drives the More Info "Loading…" note.
    private var aboutResolving: Bool {
        // Do NOT gate on aboutFullArticleAttempted — that fetch is deliberately
        // skipped when a README exists, which would otherwise spin forever.
        let haveLong = !(aboutLongForm?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if haveLong { return false }
        if aboutResolveCompleted { return false }
        return readmeLoading || aboutWebBlurbLoading || !aboutResolveCompleted
    }

    // Short description for the panel blurb row when there's NO long-form.
    private var aboutPanelBlurb: String? {
        if let b = aboutWebBlurb?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty { return b }
        if let h = homepageMeta?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty { return h }
        return nil
    }

    // More Info earns its place when there is genuinely MORE content than the
    // single Overview blurb: a full README, a project-wiki blurb, OR homepage
    // metadata (description/image) for the rich panel. Otherwise we hide it.
    private var hasAboutDetail: Bool {
        if !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return true }
        if !(aboutFullArticle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return true }
        if !(projectWikiBlurb?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return true }
        if let m = homepageMeta {
            if !(m.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return true }
            if m.imageURL != nil { return true }
        }
        return false
    }

    // The tabs shown in the segmented strip. Every Homebrew package has a
    // homepage (verified across the full catalog), so More Info is essentially
    // always populated; we render it permanently for a stable strip (no
    // pop-in once homepage meta resolves). The loading note covers the fetch.
    private var visibleTabs: [DetailTab] {
        DetailTab.allCases
    }

    // Size card label: "Size" for an installed formula's real on-disk Cellar
    // footprint, "Download Size" when showing the network-probed compressed
    // bottle size for a formula that isn't installed yet.
    private var sizeStatLabel: String {
        installed?.sizeDisplay != nil ? "Size" : "Download Size"
    }

    // Size card value: prefer the installed on-disk size; else the fetched
    // bottle download size; else an em dash while unknown / fetching.
    private var sizeStatValue: String {
        if let onDisk = installed?.sizeDisplay { return onDisk }
        guard let bytes = bottleSizeBytes, bytes > 0 else { return "—" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    var body: some View {
        // The top of the card (back, header, stats, and the tab picker) is
        // FIXED; only the selected tab's body scrolls beneath it, mirroring the
        // cask detail card.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                backRow
                    .padding(.top, 12)
                headerSection
                Divider()
                statsRow
                Divider()
                tabPicker
            }
            .padding(.horizontal)
            // Small top inset, IDENTICAL to BrowseView and the cask card. This
            // only works because the card now carries a `.toolbar` (see below):
            // the presence of a toolbar makes AppKit RESERVE the title-bar
            // safe-area gap for this column, so 6pt sits just below the title
            // bar. Without the toolbar the column got no gap and ANY padding (6
            // or 38) drew INTO the title bar, clipping the Back button.
            .padding(.top, 6)
            .padding(.bottom, 12)
            // Solid opaque header fill so the scrolling tab content below cannot
            // ghost through the fixed header. Stays WITHIN the safe area (no
            // .ignoresSafeArea), identical to BrowseView. Combined with
            // .hardScrollEdge on the scroll view below, this defeats the macOS
            // 26 scroll-edge fade without extending into the title bar.
            .background(Color(nsColor: .windowBackgroundColor))

            // Only the tab content scrolls; the info column on the right is
            // pinned OUTSIDE the scroll view so it never moves. The ScrollView
            // now wraps only the left column, so its scroll indicator lands at
            // the right edge of the content — just to the LEFT of the info box —
            // so the user can see when the text is scrollable.
            HStack(alignment: .top, spacing: 24) {
                ScrollView {
                    tabBody
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .hardScrollEdge(.top)
                // The right-side info column sits in its OWN ScrollView so its
                // intrinsic content height can NEVER drive the window size.
                // It previously used .fixedSize(vertical: true), which makes a
                // view claim its full intrinsic height and ignore the parent
                // proposal; in an alignment-top HStack that pinned the whole row
                // to the info column's tall content height, and with
                // windowResizability contentMinSize the window grew to fit it
                // whenever a taller detail card opened. Letting it fill and
                // scroll internally means the row claims only the height the
                // window already offers, so navigation no longer resizes it.
                // IDENTICAL to the cask detail card.
                ScrollView {
                    infoSidebar
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.never)
                .frame(width: 260)
                .padding(.trailing)
                .padding(.top)
            }
        }
        // Fill the available space and pin content to the TOP, matching the cask
        // detail card exactly (alignment: .top, not .topLeading). The parent
        // presents this card inside a Group with .frame(maxWidth: .infinity,
        // maxHeight: .infinity) (no alignment = .center); pinning .top here keeps
        // the fixed header / Back button at its intended y regardless of the
        // post-install relayout.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The install/uninstall progress HUD is NOT rendered here — it lives as a
        // single centered overlay at the app root (see ForgedBrewApp), fed by
        // appData.installProgress[formula.name], which the SHARED install manager
        // now publishes (the buttons call appData.startInstall/startUninstall).
        // That keeps the HUD always visible and identical to the cask card, and
        // never disturbs this card's header / Back button.
        //
        // When the operation finishes, refresh the shared installed set so the
        // button flips Install↔Installed and the Uninstall button appears/
        // disappears immediately — exactly the cask card's progressPhaseKey
        // handler. (finish() in the manager only sets the phase; it doesn't
        // refresh the installed set itself.)
        .onChange(of: progressPhaseKey) {
            guard progressPhaseKey == "finished" else { return }
            Task { await appData.refreshInstalled() }
        }
        // Lazily enrich with dependencies + HEAD version from the single-formula
        // API. Keyed on name so navigating to a different formula re-fetches.
        .task(id: formula.name) {
            await loadDetail()
        }
        .task(id: formula.name) {
            await loadBottleSize()
        }
        .task(id: formula.name) {
            await loadCatalogDate()
        }
        .task(id: formula.name) {
            await resolveRepoAndExtras()
        }
        // Overview/About content is NOT warmed eagerly: it is resolved lazily
        // when the user opens the Overview / More Info tab (see
        // ensureOverviewLoaded / ensureAboutLoaded), so each tab shows its
        // "Loading…" note while its sources resolve — mirroring Screenshots.
        // Resolve a homepage-preview screenshot for the Screenshots tab.
        .task(id: formula.name) {
            await resolveScreenshots()
        }
        // Load any saved note for this formula (keyed by name, same as tags).
        .task(id: formula.name) {
            note = (try? await appData.db.fetchNote(token: formula.name)) ?? ""
        }
        // A toolbar is what makes AppKit reserve the title-bar safe-area gap for
        // this detail column (the browse pages get this for free via their sort
        // toolbar). Without it, the column has NO title-bar gap and the header
        // draws into the title bar with the Back button clipped — no amount of
        // top padding fixes that. We keep the toolbar empty (the Back button and
        // header live in the body) so it changes nothing visually except the
        // reserved gap. IDENTICAL to the cask card.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        // Admin-password prompt for privileged formula operations. The shared
        // install manager raises a SudoRequest when an operation needs a
        // password; without this sheet the card would set `.needsPassword` and
        // hang forever ("Waiting for admin password…") because no UI was bound
        // to present the prompt. Mirrors the cask DetailView / InstalledView.
        .sheet(item: sudoRequestBinding) { request in
            SudoPasswordSheet(
                request: request,
                validate: { await appData.validateSudoPassword($0) }
            ) { password in
                appData.provideSudoPassword(password, for: request)
            }
        }
    }

    // Binding over the shared install manager's outstanding sudo request, so the
    // password sheet presents via `.sheet(item:)`. Setting it to nil (sheet
    // dismiss) is treated as a cancel and clears the queued operation. IDENTICAL
    // to the cask DetailView.
    private var sudoRequestBinding: Binding<SudoRequest?> {
        Binding(
            get: { appData.pendingSudoRequest },
            set: { newValue in
                if newValue == nil, let current = appData.pendingSudoRequest {
                    appData.provideSudoPassword(nil, for: current)
                }
            }
        )
    }

    // MARK: Back

    // Solid green Capsule pill with a white label, matching the cask detail
    // card's Back button EXACTLY: filled accent Capsule (rest opacity 0.47,
    // full green on hover), white label, stroke 1->1.5 on hover, accent glow
    // on hover, and a 1.03 hover scale. So Back reads as a real filled button
    // (not tinted text) and both detail cards match.
    private var backRow: some View {
        Button(action: onBack) {
            Label("Back", systemImage: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                // Solid white label so it reads as a filled button, not tinted text.
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    // A clearly visible, darker-green filled pill. Default state
                    // already reads as a real button; hover brightens it for
                    // obvious feedback. Capsule + accent green keeps it on brand.
                    Capsule()
                        .fill(Color.accentColor
                              .opacity(isBackHovered ? 1.0 : 0.47))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.accentColor
                            .opacity(isBackHovered ? 1.0 : 0.47),
                            lineWidth: isBackHovered ? 1.5 : 1)
                )
                // Stronger glow lift on hover for obvious affordance.
                .shadow(color: Color.accentColor.opacity(isBackHovered ? 0.55 : 0.0),
                        radius: isBackHovered ? 8 : 0, y: 1)
                .scaleEffect(isBackHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isBackHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isBackHovered)
    }

    // MARK: Header (glyph + name + badges + desc + action row + command box)

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                // CLI glyph — formulae have no app icon, so we keep the green
                // terminal tile used everywhere else for formulae.
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.green.gradient)
                    .frame(width: 92, height: 92)
                    .overlay {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(formula.name)
                            .font(.largeTitle.bold())
                            .textSelection(.enabled)
                        FavoriteButton(token: formula.name, showHint: isHeaderHovered, hintTrailing: true)
                            .scaleEffect(1.3)
                        Spacer(minLength: 0)
                    }

                    Text(formula.subcategory)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12), in: Capsule())

                    // Deprecation / disabled badge — same precedence as before:
                    // disabled (install will fail) outranks deprecated.
                    if displayFormula.disabled {
                        Label("Disabled", systemImage: "xmark.octagon.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.red, in: Capsule())
                            .help("Homebrew has disabled this formula — it is no longer supported and installing it will fail.")
                            .padding(.top, 2)
                    } else if displayFormula.deprecated {
                        Label("Deprecated", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange, in: Capsule())
                            .help("Homebrew has deprecated this formula. It may be unmaintained, superseded, or scheduled for removal — installing it is discouraged.")
                            .padding(.top, 2)
                    }

                    if let desc = formula.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.body)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onHover { isHeaderHovered = $0 }

            actionRow

            // Live operation progress sits right below the action buttons,
            // replacing the brew-install command box while an install/uninstall
            // is in flight (or just finished/failed, until the manager clears
            // it). Uses the SHARED InstallHUD inline variant — green for
            // install, red for uninstall — keyed by formula.name, exactly like
            // the cask detail card. This restores the inline progress bar that
            // was lost when the old centered app-root HUD was removed.
            if let progress = appData.installProgress[formula.name] {
                InstallHUD(
                    appName: formula.name,
                    progress: progress,
                    inline: true
                )
            } else {
                Text("brew install \(formula.name)")
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Action buttons

    private var actionRow: some View {
        HStack(spacing: 12) {
            installButton

            // Prefer the formula's real homepage; fall back to the resolved
            // GitHub repo only when there's no homepage. (The dedicated GitHub
            // Page button below links the repo, so Homepage shouldn't duplicate
            // it.)
            if let homepageURL = formula.homepage.flatMap(URL.init(string:)) ?? repoURL {
                DetailActionButton(
                    title: "Homepage",
                    systemImage: "safari.fill",
                    tint: .blue,
                    isProminent: false
                ) {
                    NSWorkspace.shared.open(homepageURL)
                }
            }

            // Opens this formula's page on formulae.brew.sh (the canonical
            // Homebrew listing). Mirrors the cask detail view's button.
            if let brewPageURL = DetailViewModel.homebrewPageURL(forFormula: formula.name) {
                DetailActionButton(
                    title: "Homebrew Page",
                    systemImage: "mug.fill",
                    tint: ActionColors.homebrew,
                    isProminent: true
                ) {
                    NSWorkspace.shared.open(brewPageURL)
                }
            }

            // GitHub Page — only when we resolved a source repo for this
            // formula (a github.com homepage, or a host-matched search result).
            if let repoURL {
                DetailActionButton(
                    title: "GitHub Page",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    tint: ActionColors.github,
                    isProminent: true
                ) {
                    NSWorkspace.shared.open(repoURL)
                }
            }

            DetailActionButton(
                title: didCopyCommand ? "Copied!" : "Copy Command",
                systemImage: didCopyCommand ? "checkmark" : "doc.on.doc.fill",
                tint: .gray,
                isProminent: false
            ) {
                copyInstallCommand()
            }

            // Explicit Uninstall button, shown only when the formula is
            // installed. Pushed to the far right so this destructive action
            // stays out of the way of the everyday buttons.
            if isInstalled {
                Spacer(minLength: 16)
                DetailActionButton(
                    title: "Uninstall",
                    systemImage: "trash",
                    tint: ActionColors.destructive
                ) {
                    // Shared manager, same as the cask Uninstall button —
                    // gated on the session admin password first.
                    Task {
                        guard let password = await appData.ensureSessionSudoPassword(
                            verb: "remove", subject: formula.name
                        ) else { return }
                        appData.startUninstall(token: formula.name, isFormula: true, sudoPassword: password)
                    }
                }
            }
        }
        // Disable EVERY action (Install / Update / Uninstall) while a brew
        // operation is in flight. Busy state comes from the SHARED manager
        // (keyed by this formula's token) — IDENTICAL to the cask card — so the
        // row stays locked even if the user navigates away and back mid-install,
        // and so a fresh install (which links the binary partway through and
        // flips `isInstalled` true, revealing the Uninstall button) can't be
        // interrupted by tapping Uninstall on a half-installed package.
        .disabled(actionInProgress)
        .opacity(actionInProgress ? 0.5 : 1.0)
    }

    // True while a brew operation for this formula is in flight, read from the
    // shared install manager (appData.isOperationInFlight) exactly like the cask
    // card's `isBusy`. Replaces the old view-local isWorking/actionSucceeded
    // flags, which were driven by an inline per-line stream loop that re-rendered
    // the card on every brew output line and made the window jump.
    private var actionInProgress: Bool {
        appData.isOperationInFlight(token: formula.name)
    }

    // Single-function status/action button matching the cask card:
    //   • Install   (not installed)         → start the install
    //   • Update    (installed & outdated)   → start the upgrade
    //   • Installed (installed & current)    → disabled status badge, no-op
    @ViewBuilder
    private var installButton: some View {
        let isInstalledAndNotOutdated = isInstalled && !isOutdated
        let title = isInstalled ? (isOutdated ? "Update" : "Installed") : "Install"
        let icon = isInstalled ? (isOutdated ? "arrow.up.circle" : "checkmark.circle") : "arrow.down.circle"
        let tint: Color = isInstalled
            ? (isOutdated ? ActionColors.update : ActionColors.installed)
            : ActionColors.install
        DetailActionButton(
            title: title,
            systemImage: icon,
            tint: tint,
            isProminent: !isInstalledAndNotOutdated
        ) {
            // Route through the SHARED install manager (AppDataService) exactly
            // like the cask card's installButton — NOT an inline per-line stream
            // loop. The manager owns the brew stream off the view, so the detail
            // card no longer re-renders on every output line; that per-line view
            // churn was what made the window (sidebar + header) jump during an
            // install. Progress is observed via appData.installProgress[token],
            // which the single centered app-root HUD already reads.
            // Gate on the session admin password first (prompt once per
            // session via the sheet, reuse after, cancel aborts), then hand it
            // to the shared manager — IDENTICAL to the cask card. Without this
            // up-front gate a privileged formula stalls at
            // "Waiting for admin password…" because no sheet was bound.
            if isInstalled {
                if isOutdated {
                    Task {
                        guard let password = await appData.ensureSessionSudoPassword(
                            verb: "update", subject: formula.name
                        ) else { return }
                        appData.startInstall(token: formula.name, isUpgrade: true, isFormula: true, sudoPassword: password)
                    }
                }
                // installed & current → no-op (Uninstall lives on its own button)
            } else {
                Task {
                    guard let password = await appData.ensureSessionSudoPassword(
                        verb: "install", subject: formula.name
                    ) else { return }
                    appData.startInstall(token: formula.name, isFormula: true, sudoPassword: password)
                }
            }
        }
        .disabled(isInstalledAndNotOutdated)
    }

    private func copyInstallCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("brew install \(formula.name)", forType: .string)
        didCopyCommand = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { didCopyCommand = false }
        }
    }

    // MARK: Stat cards

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatCard(label: sizeStatLabel, value: sizeStatValue, icon: "internaldrive")
            StatCard(label: "Kind", value: "CLI", icon: "terminal")
            StatCard(label: "Version", value: displayFormula.displayVersion, icon: "number")
            StatCard(label: "Last Catalog Update", value: lastUpdatedDisplay ?? "—", icon: "calendar")
            StatCard(label: "Status",
                     value: statusStatValue,
                     icon: statusStatIcon)
        }
    }

    // Status card value. Deprecation/disabled take precedence over install
    // state because they are the more important signal.
    private var statusStatValue: String {
        if displayFormula.disabled { return "Disabled" }
        if displayFormula.deprecated { return "Deprecated" }
        return isInstalled ? (isOutdated ? "Outdated" : "Installed") : "Not installed"
    }

    private var statusStatIcon: String {
        if displayFormula.disabled { return "xmark.octagon" }
        if displayFormula.deprecated { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    // "Last Updated": prefers the REAL catalog date — when this formula's .rb
    // file was last committed in Homebrew/homebrew-core — resolved lazily from
    // GitHub on open (catalogLastUpdated). Falls back to brew's local
    // install/upgrade date for installed formulae, then nil ("—"). Never faked.
    private var lastUpdatedDisplay: String? {
        if let catalog = catalogLastUpdated {
            return catalog.formatted(date: .abbreviated, time: .omitted)
        }
        if let date = appData.installedByToken[formula.name]?.installedDate {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return nil
    }

    // MARK: - Tabbed Content

    // Light, eye-catching color for the "select a tab" hint — matches the cask
    // card so both surfaces use the same fixed soft blue.
    private var hintColor: Color { Color(red: 0.30, green: 0.62, blue: 0.96) }

    // The tab picker (hint + segmented control). Lives in the FIXED header so
    // the user can switch tabs without scrolling back up; only the tab body
    // below it scrolls.
    private var tabPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let period = 1.4
                    let raw = (t.truncatingRemainder(dividingBy: period)) / period
                    let eased = 0.5 - 0.5 * cos(raw * 2 * Double.pi)
                    let nudge = CGFloat(eased) * 5

                    HStack(spacing: 5) {
                        Text("Select a tab for more information")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .offset(x: nudge)
                            .opacity(0.6 + 0.4 * eased)
                    }
                    .foregroundStyle(hintColor)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Select a tab to the right for more information")
                Picker("Select Tab", selection: $selectedTab) {
                    ForEach(visibleTabs, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: visibleTabs) { _, tabs in
                    if !tabs.contains(selectedTab) { selectedTab = .overview }
                }
            }
        }
    }

    // The body of the currently-selected tab. This is the SCROLLABLE region;
    // the fixed header (incl. tabPicker) sits above it.
    @ViewBuilder private var tabBody: some View {
            switch selectedTab {
            case .overview:
                ReadmeView(text: overviewText, fallback: formula.desc, isLoading: overviewResolving, isUpgrading: overviewUpgrading)
                    // Opening the tab kicks the lazy resolve of the Overview's
                    // sources (README, Wikipedia blurb, project-wiki) so the
                    // "Loading…" note shows while they resolve.
                    .task(id: formula.name) {
                        await ensureOverviewLoaded()
                    }
            case .screenshots:
                // Formulae publish no real screenshots, so we show a rendered
                // snapshot of the homepage (labeled "Homepage preview"); the
                // placeholder's About text is the fallback when even that fails.
                ScreenshotsView(urls: screenshotURLs, aboutText: aboutText, isHomepagePreview: screenshotsAreHomepagePreview, isLoading: screenshotsLoading)
            case .dependencies:
                dependenciesTab
            case .about:
                AboutView(
                    formula: displayFormula,
                    markdown: aboutLongForm,
                    repoURL: repoURL,
                    license: LicenseFormatting.friendlyType(for: githubLicense) ?? displayFormula.licenseType,
                    isLoading: aboutResolving,
                    webBlurb: aboutPanelBlurb,
                    webBlurbLoading: aboutWebBlurbLoading,
                    markdownSourceName: {
                        switch aboutLongFormSource {
                        case .readme: return "README on GitHub"
                        case .homepage: return "project homepage"
                        case .wikipedia: return "full article on Wikipedia"
                        case .projectWiki: return "project wiki"
                        }
                    }(),
                    markdownSourceURL: {
                        switch aboutLongFormSource {
                        case .readme: return repoURL
                        case .homepage: return formula.homepage.flatMap(URL.init(string:))
                        case .wikipedia: return DetailViewModel.wikipediaArticleURL(for: formula.name)
                        case .projectWiki: return repoURL
                        }
                    }(),
                    isReadme: aboutLongFormIsReadme
                )
                .task(id: formula.name) {
                    await ensureAboutLoaded()
                }
            }
    }

    // A short "about" text for the Screenshots placeholder: the README's first
    // meaningful paragraph if we have one, else the Homebrew description.
    private var aboutText: String? {
        if let md = readme, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for line in md.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && !t.hasPrefix("#") && !t.hasPrefix("![") && !t.hasPrefix("<") {
                    return t
                }
            }
        }
        return formula.desc
    }

    // Dependencies tab: runtime + build dependency chips, or a loading hint
    // while the lazy detail fetch is in flight, or an explicit "none" state.
    @ViewBuilder
    private var dependenciesTab: some View {
        if !displayFormula.dependencies.isEmpty || !displayFormula.buildDependencies.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !displayFormula.dependencies.isEmpty {
                    depGroup(title: "Dependencies", items: displayFormula.dependencies)
                }
                if !displayFormula.buildDependencies.isEmpty {
                    depGroup(title: "Build Dependencies", items: displayFormula.buildDependencies)
                }
            }
            .padding()
        } else if isLoadingDetail {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("Loading dependencies…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else {
            Text("No dependencies")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    private func depGroup(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            FlowChips(items: items)
        }
    }

    // MARK: - Info Sidebar

    private var infoSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoRow(label: "Homepage", value: formula.homepage ?? "—", isLink: true)
            infoRow(label: "Version", value: displayFormula.displayVersion)
            infoRow(label: "Identifier", value: formula.name, monospaced: true)
            infoRow(label: "Category", value: formula.subcategory)
            infoRow(label: "License",
                    value: LicenseFormatting.friendlyType(for: githubLicense) ?? displayFormula.licenseType ?? "Unknown")
            infoRow(label: "Last Catalog Update", value: lastUpdatedDisplay ?? "—")
            infoRow(label: "Installs (30d)",
                    value: displayFormula.installCount30d > 0 ? displayFormula.installCount30d.formatted() : "—")
            if let head = headVersion {
                infoRow(label: "HEAD", value: head)
            }
            Divider()
            noteSection
            Divider()
            TagSection(token: formula.name, type: .formula)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private func infoRow(label: String, value: String, isLink: Bool = false, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Label: small, uppercased, letter-spaced — a refined section label
            // rather than a raw field name, matching the app's heading style.
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            // Value: clean system text (not the old terminal-style monospace).
            // Identifiers/tokens opt into monospace via `monospaced: true` so
            // they still read as code, but at a tighter, on-theme size.
            if isLink, let url = URL(string: value), url.scheme?.hasPrefix("http") == true {
                Link(destination: url) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .opacity(0.7)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else if monospaced {
                Text(value)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Lazy loaders

    // Fetches the full single-formula record when the catalog copy lacks
    // dependencies. Errors are non-fatal: we keep showing the catalog data.
    private func loadDetail() async {
        guard formula.dependencies.isEmpty, formula.buildDependencies.isEmpty else { return }
        if let enriched, enriched.name == formula.name { return }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let full = try await appData.api.fetchFormula(name: formula.name)
            guard full.name == formula.name else { return }
            enriched = full
        } catch {
            // Non-fatal — keep showing the catalog data we already have.
        }
    }

    // For NOT-installed formulae, probe the bottle download size for this Mac
    // over the network (best-effort). Installed formulae show their on-disk size.
    private func loadBottleSize() async {
        guard installed == nil else { return }
        if let bytes = await appData.api.fetchBottleSize(name: formula.name) {
            guard installed == nil else { return }
            bottleSizeBytes = bytes
        }
    }

    // Resolve the catalog last-updated date from GitHub commit history of this
    // formula's .rb file in Homebrew/homebrew-core. Best-effort + disk-cached.
    private func loadCatalogDate() async {
        let first = formula.name.first.map { String($0).lowercased() } ?? "a"
        let path = "Formula/\(first)/\(formula.name).rb"
        let resolved = await appData.api.catalogLastUpdated(
            repo: "Homebrew/homebrew-core",
            path: path,
            id: "formula/\(formula.name)"
        )
        if let resolved { catalogLastUpdated = resolved }
    }

    // Resolve a GitHub repo for this formula (homepage if it's github.com, else
    // a best-effort host-matched search) and, when found, warm the license from
    // the same cached /repos response. README + Wikipedia are fetched lazily
    // when the About tab is opened (see ensureAboutLoaded).
    private func resolveRepoAndExtras() async {
        guard !repoResolved else { return }
        repoResolved = true
        var url = formula.githubURL
        if url == nil {
            url = await appData.api.searchRepoURL(
                token: formula.name,
                appName: formula.name,
                homepage: formula.homepage
            )
        }
        resolvedRepoURL = url
        if let url {
            githubLicense = try? await appData.api.fetchGitHubLicense(repoURL: url)
        }
    }

    // Lazy loader for the Overview tab. Resolves the short-description sources
    // in Overview's priority order: README (project's own words), Wikipedia
    // "about" blurb, then the project-wiki Home blurb. Each phase guards
    // itself, so opening the tab triggers it via .task without re-fetching.
    private func ensureOverviewLoaded() async {
        // README first (only if a repo is known and we haven't tried yet).
        if readme == nil, !readmeAttempted, let url = repoURL {
            readmeAttempted = true
            readmeLoading = true
            readme = try? await appData.api.fetchGitHubReadme(repoURL: url)
            readmeLoading = false
        }
        // Wikipedia blurb (Overview's preferred clean summary), once.
        if !aboutWebBlurbAttempted {
            aboutWebBlurbAttempted = true
            aboutWebBlurbLoading = true
            aboutWebBlurb = await appData.api.fetchAboutBlurb(appName: formula.name, homepage: formula.homepage)
            aboutWebBlurbLoading = false
        }
        // Homepage metadata (description / og:image) once, as a later fallback.
        if !homepageMetaAttempted {
            homepageMetaAttempted = true
            homepageMeta = await appData.api.fetchHomepageMeta(homepage: formula.homepage)
        }
        // Project-wiki fallback only when we still have neither blurb nor README.
        let haveBlurb = !(aboutWebBlurb?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let haveReadme = !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !projectWikiAttempted, !haveBlurb, !haveReadme, let repo = repoURL {
            projectWikiAttempted = true
            projectWikiBlurb = await appData.api.fetchGitHubWikiBlurb(repoURL: repo)
        }
        overviewResolveCompleted = true
    }

    // Two-phase lazy load for the About tab, mirroring the cask card: fetch the
    // README when a repo is known; if there's no README, fall back to a
    // Wikipedia summary blurb so the tab is never blank.
    private func ensureAboutLoaded() async {
        // Mark the whole pass complete on any exit path so aboutResolving stops
        // spinning even when later fetches are deliberately skipped.
        defer { aboutResolveCompleted = true }
        // Phase 1: README (only if we have a repo and haven't tried yet).
        if readme == nil, !readmeAttempted, let url = repoURL {
            readmeAttempted = true
            readmeLoading = true
            readme = try? await appData.api.fetchGitHubReadme(repoURL: url)
            readmeLoading = false
        }
        // Phase 2: if there's still no README, try a Wikipedia blurb once.
        let haveReadme = !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !haveReadme, !aboutWebBlurbAttempted {
            aboutWebBlurbAttempted = true
            aboutWebBlurbLoading = true
            aboutWebBlurb = await appData.api.fetchAboutBlurb(appName: formula.name, homepage: formula.homepage)
            aboutWebBlurbLoading = false
        }

        // Phase 3: homepage metadata (title / description / og:image), once.
        if !homepageMetaAttempted {
            homepageMetaAttempted = true
            homepageMeta = await appData.api.fetchHomepageMeta(homepage: formula.homepage)
        }

        // Phase 4: project-wiki fallback — only when we still have NEITHER a
        // Wikipedia blurb NOR a README, and a GitHub repo is known.
        let haveBlurb = !(aboutWebBlurb?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let haveReadme2 = !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !projectWikiAttempted, !haveBlurb, !haveReadme2, let repo = repoURL {
            projectWikiAttempted = true
            projectWikiBlurb = await appData.api.fetchGitHubWikiBlurb(repoURL: repo)
        }

        // Phase 5: FULL Wikipedia article for the More Info long-form panel —
        // only when there is NEITHER a README NOR a homepage description, since
        // both now outrank Wikipedia as long-form (homepage is the project's
        // own copy and never name-collides). Skipping the fetch when we already
        // have better content also avoids a needless (and gate-prone) lookup.
        let haveHomeDesc = !((homepageMeta?.description)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !aboutFullArticleAttempted, !haveReadme2, !haveHomeDesc {
            aboutFullArticleAttempted = true
            aboutFullArticle = await appData.api.fetchWikipediaFullArticle(appName: formula.name, homepage: formula.homepage)
        }
    }

    // Resolve a homepage-preview screenshot for the Screenshots tab. Formulae
    // publish no real screenshots, so we render a snapshot of the homepage
    // (preferred) or the formulae.brew.sh page (last resort) via the same cached
    // pipeline the cask card uses. Cached per-name so reopening is instant.
    private func resolveScreenshots() async {
        guard !screenshotsResolved, !screenshotsLoading else { return }
        screenshotsResolved = true
        screenshotsLoading = true
        defer { screenshotsLoading = false }
        let cache = ForgedBrewCacheService.shared
        let version = displayFormula.displayVersion

        // Cached result for this version? Use it and skip the network.
        if await cache.hasCachedScreenshotResult(token: formula.name, version: version) {
            screenshotURLs = await cache.cachedScreenshots(token: formula.name, version: version)
            screenshotsAreHomepagePreview = !screenshotURLs.isEmpty
            return
        }

        // Make sure homepage metadata has been attempted so its og:image (a
        // real, curated banner) can be the first visual candidate.
        if !homepageMetaAttempted {
            homepageMetaAttempted = true
            homepageMeta = await appData.api.fetchHomepageMeta(homepage: formula.homepage)
        }

        // Candidate order: the homepage's own og:image (a real image the
        // project chose), then a rendered homepage snapshot, then the
        // formulae.brew.sh page snapshot — so the tab always shows something.
        var candidates: [URL] = []
        if let og = homepageMeta?.imageURL { candidates.append(og) }
        if let home = DetailViewModel.homepageThumbnailURL(homepage: formula.homepage) { candidates.append(home) }
        if let brew = DetailViewModel.homebrewPageThumbnailURL(forFormula: formula.name) { candidates.append(brew) }
        guard !candidates.isEmpty else { return }

        let localURLs = await cache.storeScreenshots(
            remoteURLs: candidates,
            token: formula.name,
            version: version
        )
        screenshotURLs = localURLs
        screenshotsAreHomepagePreview = !localURLs.isEmpty
    }

    // MARK: - My Note (identical treatment to the cask detail card)

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("My Note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if noteJustSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            TextEditor(text: $note)
                .font(.system(size: 12))
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
            HStack(spacing: 8) {
                Spacer()
                if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Remove Note", role: .destructive) {
                        Task {
                            note = ""
                            try? await appData.db.saveNote(token: formula.name, note: note)
                            await flashNoteSaved()
                            await appData.loadNotesAndTagsCount()
                        }
                    }
                    .buttonStyle(OutlinedButtonStyle())
                    .controlSize(.small)
                    .help("Delete this note")
                }
                Button("Save Note") {
                    Task {
                        try? await appData.db.saveNote(token: formula.name, note: note)
                        await flashNoteSaved()
                        await appData.loadNotesAndTagsCount()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: noteJustSaved)
    }

    // Brief "Saved" confirmation, matching the cask card's saveNote feedback.
    private func flashNoteSaved() async {
        noteJustSaved = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        noteJustSaved = false
    }

    // Install/uninstall/upgrade are driven through the SHARED install manager
    // (appData.startInstall / appData.startUninstall with isFormula: true),
    // exactly like the cask card. The manager owns the brew AsyncStream off-view
    // and publishes coarse phase changes into appData.installProgress[token], so
    // this card only re-renders on phase transitions — never per output line.
    // The single centered HUD at the app root (see ForgedBrewApp) renders the
    // progress identically for casks and formulae, and the card's
    // progressPhaseKey onChange refreshes the installed set when the op finishes.
}

// MARK: - FlowChips
// Simple wrapping row of chip-styled labels for dependency lists.
struct FlowChips: View {
    let items: [String]

    private let columns = [GridItem(.adaptive(minimum: 90, maximum: 200), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
