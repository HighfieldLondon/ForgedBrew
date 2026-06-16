import Foundation
import SwiftUI
import AppKit

enum InstallState: Equatable, Sendable {
    case idle
    case installing
    case installed
    case uninstalling
    case error(String)
}

enum DetailTab: String, CaseIterable, Sendable {
    case overview = "Overview"
    // "Detailed Info" sits right after Overview. It shows the project README
    // when one exists, and otherwise a rich metadata + Wikipedia-blurb panel,
    // so the tab is never blank (see AboutView).
    case about = "Detailed Info"
    case screenshots = "Screenshots"
    case dependencies = "Dependencies"
}

@MainActor
@Observable
final class DetailViewModel {
    var cask: CaskMetadata
    var isInstalled: Bool = false
    var installedVersion: String? = nil
    var isOutdated: Bool = false
    var githubStars: Int? = nil
    // Real SPDX license ("MIT", "GPL-3.0", …) resolved from GitHub for casks
    // with a repo. nil means unknown/non-GitHub. Persisted to the githubMeta
    // cache so cards can show it later without re-fetching.
    var githubLicense: String? = nil
    // The date this cask's .rb file was last committed in Homebrew/homebrew-cask
    // — the real "last updated in the catalog" date. Homebrew's JSON API does
    // not expose this, so we resolve it lazily from GitHub commit history and
    // cache it on disk. nil until resolved (or when GitHub is unavailable); the
    // detail card then falls back to the local install date.
    var catalogLastUpdated: Date? = nil
    var readme: String? = nil
    var screenshotURLs: [URL] = []
    // True while screenshots/README are still being resolved (cache check +
    // possible network fetch + page render). Drives the Screenshots tab's
    // "Loading…" note so a slow gallery reads as still-working rather than empty.
    var screenshotsLoading: Bool = false
    // True while the GitHub README is still being resolved (the repo lookup +
    // README fetch happen during load()). Drives the README tab's "Loading…"
    // note so a slow fetch reads as still-working rather than empty.
    var readmeLoading: Bool = false
    // Wikipedia "about" blurb, the About tab's last-resort content for
    // closed-source apps with no GitHub repo/README. Resolved lazily the
    // first time the About tab is opened on such an app.
    var aboutWebBlurb: String? = nil
    var aboutWebBlurbLoading: Bool = false
    // Set once we've attempted the web-blurb fetch, so a confirmed miss
    // isn't retried on every tab switch.
    var aboutWebBlurbAttempted: Bool = false
    // Homepage HTML metadata (title / meta or OG description / og:image),
    // fetched once per app from the homepage. Enriches the Overview / More Info
    // tabs for apps with a rich homepage but no Wikipedia article or README
    // (e.g. cloudflared), and its og:image is offered as a screenshot candidate.
    var homepageMeta: BrewAPIService.HomepageMeta? = nil
    var homepageMetaAttempted: Bool = false
    // A "project wiki" blurb (GitHub repo wiki Home page) — a secondary source
    // for apps whose Wikipedia article is missing but whose project keeps its
    // own wiki. Fetched at most once per app and only when needed.
    var projectWikiBlurb: String? = nil
    var projectWikiAttempted: Bool = false
    // FULL Wikipedia article text (Markdown, with section headings) for the
    // More Info tab's long-form content when there is no GitHub README. This is
    // the whole page of detail, NOT the short Overview summary.
    var aboutFullArticle: String? = nil
    var aboutFullArticleAttempted: Bool = false
    // Set true once ensureAboutLoaded() has run to completion for this cask,
    // so aboutResolving can stop spinning even when the full-article fetch
    // was deliberately skipped (e.g. a README is present).
    var aboutResolveCompleted: Bool = false
    // Set true once ensureOverviewLoaded() has run to completion, so
    // overviewResolving stops spinning even when later fallbacks are skipped.
    var overviewResolveCompleted: Bool = false
    // The GitHub repo we actually resolved for this cask — either the homepage
    // (when it's a github.com URL) or a host-matched search result. Used so the
    // Releases tab can link to a discovered repo, not just homepage-derived ones.
    var resolvedRepoURL: URL? = nil
    var installLog: [String] = []
    var installState: InstallState = .idle
    var selectedTab: DetailTab = .overview
    // True when the screenshots we are displaying are NOT real app screenshots
    // but a rendered snapshot of the app's homepage (or, last resort, its
    // Homebrew page). Lets the Screenshots tab caption the image as a
    // "Homepage preview" so it isn't mistaken for an actual app UI shot.
    var screenshotsAreHomepagePreview: Bool = false

    // The About tab is only meaningful when there is genuinely MORE detail than
    // the Overview tab already shows. Overview now surfaces the best single
    // description (Wikipedia blurb, else README intro, else the Homebrew
    // description), so About earns its place ONLY when a full project README
    // exists (the long-form content + metadata panel is the "more"). When there
    // is no README we hide About to avoid duplicating the Overview text.
    var hasAboutDetail: Bool {
        // More Info earns its place when there is genuinely MORE long-form or
        // structured content than the single Overview blurb: a full README, a
        // project-wiki blurb, OR homepage metadata (description/image) we can
        // present in the rich panel. Otherwise we hide it to avoid duplicating
        // the Overview text.
        if !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return true }
        if !(aboutFullArticle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return true }
        if !(projectWikiBlurb?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return true }
        if let m = homepageMeta {
            if !(m.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return true }
            if m.imageURL != nil { return true }
        }
        return false
    }

    // The tabs actually shown in the segmented strip. Measured across all
    // ~16k Homebrew packages, every one has a homepage (and thus fetchable
    // metadata / long-form), so More Info is essentially always populated.
    // We therefore render it permanently for a stable strip (no pop-in once
    // homepage meta resolves); the loading note covers the fetch window and
    // the rich panel degrades gracefully in the rare thin case.
    var visibleTabs: [DetailTab] {
        DetailTab.allCases
    }

    // The SHORT summary Overview should show, in priority order. Overview is a
    // glance; the full long-form lives in More Info (aboutLongForm). Crucially
    // we use only the README *intro* here, never the whole README — otherwise
    // Overview and More Info render identical content for README-only packages
    // (e.g. KeyCastr).
    //
    // The Homebrew description leads because it is a CURATED, app-specific
    // one-liner ("Spotify is a digital music service…", "Official download of
    // VLC media player…"). The Wikipedia blurb is demoted to LAST: for apps
    // like Spotify / VLC / Webex it describes the generic category/concept, and
    // for name-collisions like Loom it is the wrong entity entirely — neither
    // belongs at the top of Overview. The long encyclopedic text still lives in
    // More Info (aboutLongForm). New order:
    //   1. Homebrew description   (curated, app-specific one-liner — best glance)
    //   2. Homepage meta/OG description (project's own short words)
    //   3. GitHub README intro    (first prose paragraph only, badges stripped)
    //   4. Project-wiki blurb     (GitHub wiki Home, for projects with no article)
    //   5. Wikipedia blurb        (generic/encyclopedic — last resort only)
    var overviewText: String? {
        let d = cask.desc?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d, !d.isEmpty { return d }
        let homeDesc = homepageMeta?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let homeDesc, !homeDesc.isEmpty { return homeDesc }
        if let md = readme?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty,
           let intro = Self.readmeIntro(from: md), !intro.isEmpty { return intro }
        let wiki = projectWikiBlurb?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wiki, !wiki.isEmpty { return wiki }
        let blurb = aboutWebBlurb?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (blurb?.isEmpty == false) ? blurb : nil
    }

    // Which source supplied the More Info long-form content. Drives the footer
    // "View this …" link label + destination.
    enum AboutLongFormSource { case readme, homepage, wikipedia, projectWiki }

    // The long-form content the More Info tab renders (full page of detail), in
    // descending order of identity confidence:
    //   1. GitHub README  — the project's own docs, strongest signal.
    //   2. Homepage text  — the project's own site description. Promoted ABOVE
    //      Wikipedia because Wikipedia name-collisions (simdjson -> "The
    //      Simpsons", bison -> the animal) are the main source of wrong cards.
    //   3. Wikipedia article — only when the homepage gives us nothing, and
    //      only after the relevance gate has confirmed it.
    //   4. Project-wiki blurb — last resort.
    var aboutLongForm: String? {
        if let md = readme?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty { return md }
        if let home = homepageMeta?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty { return home }
        if let art = aboutFullArticle?.trimmingCharacters(in: .whitespacesAndNewlines), !art.isEmpty { return art }
        if let wiki = projectWikiBlurb?.trimmingCharacters(in: .whitespacesAndNewlines), !wiki.isEmpty { return wiki }
        return nil
    }

    // The source backing aboutLongForm (mirrors the same priority order), so the
    // footer link can name + point at the right place.
    var aboutLongFormSource: AboutLongFormSource {
        if !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return .readme }
        if !((homepageMeta?.description)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return .homepage }
        if !(aboutFullArticle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return .wikipedia }
        return .projectWiki
    }

    // Whether the long-form content is the README — retained for callers that
    // only care about the README vs not distinction.
    var aboutLongFormIsReadme: Bool {
        aboutLongFormSource == .readme
    }

    // True while the Overview's preferred source (the Wikipedia blurb) is still
    // being resolved and we don't yet have it. Drives the Overview "Loading…"
    // note so the tab doesn't flash the bare Homebrew description first.
    var overviewResolving: Bool {
        // Stop as soon as we have the preferred Overview text, or once the lazy
        // Overview loader has finished its whole pass (some fallbacks may be
        // skipped, so we must not gate on individual attempt flags forever).
        let haveText = !(overviewText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if haveText { return false }
        if overviewResolveCompleted { return false }
        return aboutWebBlurbLoading || readmeLoading || !overviewResolveCompleted
    }

    // True when we already have SOMETHING to show in Overview (usually the short
    // Homebrew description) but a richer source (Wikipedia blurb / README /
    // project-wiki / homepage meta) is still being fetched. Drives the subtle
    // inline "Loading fuller description…" hint so the short text shows
    // instantly and upgrades silently when the fuller text arrives.
    var overviewUpgrading: Bool {
        if overviewResolveCompleted { return false }
        // If we already have a rich source, there's nothing better coming.
        let haveRich = !(aboutWebBlurb?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(projectWikiBlurb?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !((homepageMeta?.description)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if haveRich { return false }
        // Only hint when we actually have the short desc visible to upgrade.
        let haveDesc = !(cask.desc?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return haveDesc && (aboutWebBlurbLoading || readmeLoading || !overviewResolveCompleted)
    }

    // True while the More Info long-form is still being resolved and we don't
    // yet have it. Drives the More Info "Loading…" note for the slower fetches
    // (README, full Wikipedia article, project-wiki).
    var aboutResolving: Bool {
        // Stop as soon as we have long-form content, or once the lazy About
        // loader has finished its whole pass. We must NOT gate on
        // aboutFullArticleAttempted, because that fetch is deliberately skipped
        // when a README exists — otherwise the tab would spin forever.
        let haveLong = !(aboutLongForm?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if haveLong { return false }
        if aboutResolveCompleted { return false }
        return readmeLoading || aboutWebBlurbLoading || !aboutResolveCompleted
    }

    // The short description handed to the More Info panel's blurb row when there
    // is NO long-form content at all (homepage-only apps). Priority is the
    // app's OWN homepage description first, then the Wikipedia blurb as a last
    // resort: Wikipedia is the least reliable + least available source and the
    // only one prone to name-collisions (Slidepad -> "SureStop", Loom -> the
    // weaving device), so it never leads. The brew `desc` leads ahead of even
    // this in descriptionSection itself.
    var aboutPanelBlurb: String? {
        if let h = homepageMeta?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty { return h }
        if let b = aboutWebBlurb?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty { return b }
        return nil
    }

    // True when aboutPanelBlurb's text actually came from Wikipedia (i.e. the
    // homepage gave us nothing and we fell through to the gated Wikipedia
    // blurb). Drives the "Summary from Wikipedia" caption so it only shows when
    // the text is genuinely encyclopedic — never for homepage/brew-desc text.
    var aboutPanelBlurbIsWikipedia: Bool {
        let h = homepageMeta?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let h, !h.isEmpty { return false }
        let b = aboutWebBlurb?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (b?.isEmpty == false)
    }

    // Trust / Gatekeeper banner state (detail view). When an installed cask
    // fails Gatekeeper AND still carries the com.apple.quarantine flag, it will
    // stop opening once Homebrew drops its cask quarantine workaround (Sept 1,
    // 2026). We surface a banner with a one-tap fix right here so a user staring
    // at the app that won't launch doesn't have to hunt for the Maintenance tab.
    var trustRisk: GatekeeperRisk? = nil   // non-nil ⇒ show the banner
    var trustChecking: Bool = false        // a risk check is in flight
    var trusting: Bool = false             // the xattr -d action is in flight
    var trustJustCleared: Bool = false     // show a brief "Trusted" confirmation

    // User note for this cask (persisted in the userNotes table). Empty == no note.
    var note: String = ""
    // Briefly true right after a successful save, for transient UI feedback.
    var noteJustSaved: Bool = false
    // Briefly true right after the install command is copied, so the Copy
    // Command button can flash "Copied!" confirmation.
    var didCopyCommand: Bool = false

    // Download size (bytes) of this cask's artifact, fetched over the network
    // on detail open ONLY for apps that are NOT installed locally. Homebrew
    // publishes no size for casks, so this is the .dmg/.zip Content-Length.
    // nil means unknown / not yet fetched / fetch failed. When the app IS
    // installed, the view shows the real on-disk size instead and this stays
    // nil. `sizeIsDownload` lets the view label it distinctly ("Download").
    var downloadSizeBytes: Int64? = nil
    var sizeIsDownload: Bool = false

    init(cask: CaskMetadata) {
        self.cask = cask
    }

    // Human-readable download size ("128.4 MB"), or nil when unknown. Used by
    // the detail card stat grid for NOT-installed apps; installed apps show
    // their on-disk size from AppDataService instead.
    var downloadSizeDisplay: String? {
        guard let bytes = downloadSizeBytes, bytes > 0 else { return nil }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    // Loads the saved note for this cask from the DB. Errors leave note = "".
    func loadNote(db: DatabaseManager) async {
        note = (try? await db.fetchNote(token: cask.token)) ?? ""
    }

    // Persists the current note. An empty/whitespace note deletes the row
    // (DatabaseManager.saveNote handles that). Shows brief saved feedback.
    func saveNote(db: DatabaseManager) async {
        try? await db.saveNote(token: cask.token, note: note)
        noteJustSaved = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        noteJustSaved = false
    }

    // Homebrew/homebrew-cask stores each cask at Casks/<first-char>/<token>.rb.
    // Used as a fallback when the catalog JSON didn't carry ruby_source_path.
    static func caskRubyPath(for token: String) -> String {
        let first = token.first.map { String($0).lowercased() } ?? "a"
        return "Casks/\(first)/\(token).rb"
    }

    func load(db: DatabaseManager, api: BrewAPIService) async {
        // Flag the WHOLE media-resolution pass as loading up front. We keep this
        // true for the entire load() (not just the screenshot step) because the
        // user can open the Screenshots tab at any point during the slower
        // earlier steps (download-size probe, GitHub repo search, stars,
        // license, README) — and the screenshots themselves can't resolve until
        // the README is in hand. Showing the "Loading…" note for the whole pass
        // means the tab never reads as a premature empty state, no matter when
        // it's opened. resolveScreenshots() also re-asserts the flag so the
        // note stays put across the final network fetch + page render.
        screenshotsLoading = true
        defer { screenshotsLoading = false }
        // The README tab resolves its content during this same pass (repo
        // lookup + README fetch below). Flag it loading up front and clear it in
        // a defer so the README tab shows "Loading…" instead of a premature
        // empty state if the user opens it mid-load, no matter where load()
        // exits.
        readmeLoading = true
        defer { readmeLoading = false }
        // 1. Check installed status from db.fetchInstalled().
        //    This is a best-effort UPGRADE only: if the DB says installed we set
        //    the flags, but we must NOT downgrade an already-installed state set
        //    by the caller's earlier syncInstalledState(from: appData) — the
        //    shared in-memory set is the real source of truth. On a launch race
        //    the persisted DB can momentarily read empty/stale while the live
        //    refresh rewrites it; clobbering isInstalled to false here is exactly
        //    what made an installed app (e.g. Claude Code opened from Home right
        //    after launch) show "Install". The .onChange/sync paths reconcile a
        //    genuine uninstall, so leaving a true value untouched is safe.
        let packages = try? await db.fetchInstalled()
        if let pkg = packages?.first(where: { $0.token == cask.token }) {
            isInstalled = true
            installedVersion = pkg.installedVersion
            isOutdated = pkg.isOutdated
        } else if !isInstalled {
            isInstalled = false
            installedVersion = nil
            isOutdated = false
        }

        // 1b. For NOT-installed apps, probe the artifact download size over the
        //     network (best-effort). Installed apps show their real on-disk
        //     size in the view, so we skip the request entirely for them.
        if !isInstalled {
            if let bytes = await api.fetchDownloadSize(token: cask.token) {
                downloadSizeBytes = bytes
                sizeIsDownload = true
            }
        } else {
            downloadSizeBytes = nil
            sizeIsDownload = false
        }

        // 1c. Resolve the real "last updated in the catalog" date from the
        //     GitHub commit history of this cask's .rb file. Best-effort and
        //     disk-cached, so it costs at most one GitHub request per cask per
        //     week. Independent of the repo-resolution step below.
        let caskPath = cask.rubySourcePath ?? DetailViewModel.caskRubyPath(for: cask.token)
        catalogLastUpdated = await api.catalogLastUpdated(
            repo: "Homebrew/homebrew-cask",
            path: caskPath,
            id: "cask/\(cask.token)"
        )

        // 2. Resolve a GitHub repo for this cask. Prefer the homepage when it's
        //    already a github.com URL; otherwise fall back to a host-matched
        //    GitHub repo search (best-effort, cached, rate-limited) so apps
        //    whose homepage is their own vendor domain can still surface stars
        //    + README screenshots.
        var repoURL = cask.githubURL
        if repoURL == nil {
            repoURL = await api.searchRepoURL(
                token: cask.token,
                appName: cask.displayName,
                homepage: cask.homepage
            )
        }
        resolvedRepoURL = repoURL

        if let url = repoURL {
            // Stars and license are both decoded from a single cached /repos
            // response (see BrewAPIService.fetchGitHubRepo). We fetch stars
            // FIRST and await it before requesting the license: that first call
            // warms the per-repo cache, so the license call is served from cache
            // and costs zero additional GitHub requests. (Issuing both via
            // `async let` could race two cache-miss fetches before either
            // populates the cache.) README is a different endpoint, so it can
            // run concurrently.
            async let readmeTask = api.fetchGitHubReadme(repoURL: url)

            githubStars = try? await api.fetchGitHubStars(repoURL: url)
            githubLicense = try? await api.fetchGitHubLicense(repoURL: url)
            readme = try? await readmeTask

            // Persist the resolved license and stamp it onto the in-memory cask
            // so this detail view and its card badge reflect it immediately.
            if let lic = githubLicense {
                cask.cachedLicense = lic
                try? await db.saveCaskGitHubLicense(token: cask.token, license: lic)
            }
        }

        // 3b. Homepage metadata: fetch the homepage's <title> / description /
        //     og:image once, BEFORE screenshots, so the og:image can be offered
        //     as a real representative image in the gallery. Also enriches the
        //     Overview + More Info tabs for apps with a rich homepage but no
        //     Wikipedia article or README (e.g. cloudflared).
        if !homepageMetaAttempted {
            homepageMetaAttempted = true
            homepageMeta = await api.fetchHomepageMeta(homepage: cask.homepage)
        }

        // 4. Resolve screenshots through the cached pipeline.
        await resolveScreenshots(api: api, repoURL: repoURL)

        // NOTE: The Wikipedia "about" blurb, project-wiki fallback, and full
        // Wikipedia article are intentionally NOT fetched here. They are
        // resolved lazily when the user opens the Overview / More Info tab
        // (see ensureOverviewLoaded / ensureAboutLoaded), so each tab can show
        // its "Loading…" note while its sources resolve — mirroring the
        // Screenshots tab. README + homepage meta above are fetched eagerly
        // because the Screenshots pipeline depends on them.
    }

    // Public entry point so the Screenshots tab can lazily (re)resolve media if
    // it's opened and we somehow have neither URLs nor an in-flight load. Safe
    // to call repeatedly; the cache short-circuits a second pass.
    func ensureScreenshotsLoaded(api: BrewAPIService) async {
        guard screenshotURLs.isEmpty, !screenshotsLoading else { return }
        screenshotsLoading = true
        defer { screenshotsLoading = false }
        await resolveScreenshots(api: api, repoURL: resolvedRepoURL)
    }

    // Public entry point so the README tab can lazily fetch the repo README if
    // it is opened and we have neither README text nor an in-flight load (e.g.
    // load() finished before the README endpoint returned, or it failed). Safe
    // to call repeatedly; once we have README text or no repo to fetch from,
    // Lazy loader for the Overview tab. Resolves the short description sources
    // that are NOT already in hand from load(): the Wikipedia "about" blurb
    // (Overview's preferred source) and — only if we still have neither a
    // blurb nor a README — the project-wiki Home blurb. README + homepage meta
    // are already fetched eagerly in load(). Each phase guards itself, so this
    // is safe to call repeatedly; opening the tab triggers it via .task.
    func ensureOverviewLoaded(api: BrewAPIService) async {
        if !aboutWebBlurbAttempted, !aboutWebBlurbLoading {
            aboutWebBlurbLoading = true
            aboutWebBlurbAttempted = true
            aboutWebBlurb = await api.fetchAboutBlurb(appName: cask.displayName, homepage: cask.homepage)
            aboutWebBlurbLoading = false
        }
        let haveBlurb = !(aboutWebBlurb?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let haveReadme = !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !projectWikiAttempted, !haveBlurb, !haveReadme, let repo = resolvedRepoURL {
            projectWikiAttempted = true
            projectWikiBlurb = await api.fetchGitHubWikiBlurb(repoURL: repo)
        }
        overviewResolveCompleted = true
    }

    // it is a no-op. The underlying GitHub fetch is cached in BrewAPIService.
    func ensureReadmeLoaded(api: BrewAPIService) async {
        guard readme == nil, !readmeLoading, let url = resolvedRepoURL else { return }
        readmeLoading = true
        defer { readmeLoading = false }
        readme = try? await api.fetchGitHubReadme(repoURL: url)
    }

    // Lazy loader for the About tab. Two phases:
    //   1. If a repo is known but the README hasn't been fetched yet, fetch it
    //      (reusing ensureReadmeLoaded).
    //   2. If — after that — there is STILL no README to show (no repo at all,
    //      or the repo has no usable README), fetch a Wikipedia "about" blurb
    //      for the app name as a fallback. Attempted at most once per app.
    // Safe to call repeatedly; each phase guards itself.
    func ensureAboutLoaded(api: BrewAPIService) async {
        // Mark the whole pass complete on any exit path so aboutResolving stops
        // spinning even when later fetches are deliberately skipped.
        defer { aboutResolveCompleted = true }
        await ensureReadmeLoaded(api: api)

        let haveReadme = !(readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard !haveReadme, !aboutWebBlurbAttempted, !aboutWebBlurbLoading else { return }

        aboutWebBlurbLoading = true
        aboutWebBlurbAttempted = true
        defer { aboutWebBlurbLoading = false }
        aboutWebBlurb = await api.fetchAboutBlurb(appName: cask.displayName, homepage: cask.homepage)

        // Make sure homepage metadata is resolved before we consider Wikipedia.
        // It is normally fetched eagerly in load(), but guard against the About
        // tab opening first by resolving it here on demand.
        if !homepageMetaAttempted {
            homepageMetaAttempted = true
            homepageMeta = await api.fetchHomepageMeta(homepage: cask.homepage)
        }

        // With still no README, pull the FULL Wikipedia article ONLY when the
        // homepage gave us nothing — the homepage description now outranks
        // Wikipedia as long-form (it is the project's own copy and never
        // name-collides, unlike Wikipedia: simdjson -> "The Simpsons", etc.).
        let haveHomeDesc = !((homepageMeta?.description)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !aboutFullArticleAttempted, !haveHomeDesc {
            aboutFullArticleAttempted = true
            aboutFullArticle = await api.fetchWikipediaFullArticle(appName: cask.displayName, homepage: cask.homepage)
        }
    }

    // Screenshot resolution with on-disk caching, keyed by token + version so a
    // cask version bump re-fetches and everything else is served from disk:
    //   1. If we already resolved this token+version, load the cached image
    //      files (possibly an empty set) and stop — zero network.
    //   2. Otherwise gather candidate remote URLs: GitHub README images first,
    //      then (only if none) a SerpApi web-image search fallback, and
    //      finally the repo's GitHub social-preview banner image.
    //   3. Download + downscale + persist the set, then display the local files.
    private func resolveScreenshots(api: BrewAPIService, repoURL: URL?) async {
        // Re-assert the loading flag for the duration of THIS step specifically.
        // load() already sets it, but ensureScreenshotsLoaded() and any future
        // direct caller need it too, and the network fetch + thum.io page render
        // below are the slowest part — exactly when the "Loading…" note matters.
        screenshotsLoading = true
        defer { screenshotsLoading = false }
        let cache = ForgedBrewCacheService.shared
        let version = cask.version

        // 1. Cached result for this exact version? Use it and skip the network.
        if await cache.hasCachedScreenshotResult(token: cask.token, version: version) {
            screenshotURLs = await cache.cachedScreenshots(token: cask.token, version: version)
            return
        }

        // 2. Gather candidate remote URLs.
        var remoteCandidates: [URL] = []
        if let url = repoURL, let md = readme {
            remoteCandidates = Self.extractScreenshotURLs(from: md, repoURL: url)
        }
        // Web-search fallback only when the README produced nothing.
        if remoteCandidates.isEmpty {
            remoteCandidates = await api.searchScreenshots(token: cask.token, appName: cask.displayName, homepage: cask.homepage)
        }
        // Final visual fallback: GitHub auto-generates a social-preview (Open
        // Graph) banner image for every repo. It's a real image that almost
        // always exists, so when nothing else turned up we use it rather than
        // leaving the gallery empty. Cached + downscaled like any other shot.
        if remoteCandidates.isEmpty, let preview = Self.socialPreviewURL(for: repoURL) {
            remoteCandidates = [preview]
        }
        // Track whether everything we are about to show is a rendered page
        // preview rather than a real screenshot, so the UI can label it.
        var fromPagePreview = false

        // Next visual fallback: the homepage's own og:image (a real, curated
        // banner the project chose to represent itself). Preferred over a raw
        // page render because it's an intentional image, not a screenshot of
        // chrome. Only used when we have nothing better.
        if remoteCandidates.isEmpty, let ogImage = homepageMeta?.imageURL {
            remoteCandidates = [ogImage]
            fromPagePreview = true
        }

        // Next visual fallback: a rendered snapshot of the app's OWN homepage.
        // This is the user-preferred "snap a picture of the webpage" backup —
        // most apps/tools have a homepage even when they publish no screenshots.
        if remoteCandidates.isEmpty,
           let homeShot = Self.homepageThumbnailURL(homepage: cask.homepage) {
            remoteCandidates = [homeShot]
            fromPagePreview = true
        }

        // Last-resort visual: a rendered screenshot of this cask's
        // formulae.brew.sh page. Casks WITHOUT a GitHub repo have no social
        // preview, so without this their Screenshots tab is text-only. The
        // Homebrew page image guarantees every package shows something
        // representative. Cached + downscaled like any other shot.
        if remoteCandidates.isEmpty,
           let brewShot = Self.homebrewPageThumbnailURL(forCask: cask.token) {
            remoteCandidates = [brewShot]
            fromPagePreview = true
        }

        // 3. Download + downscale + persist; display the resulting local files.
        //    storeScreenshots always writes a "resolved" marker (even for an
        //    empty set) so we won't re-hit the network until the version changes.
        var localURLs = await cache.storeScreenshots(
            remoteURLs: remoteCandidates,
            token: cask.token,
            version: version
        )

        // Guaranteed-visual fallback. If we ended up with nothing on disk -
        // either there were no candidates, or every candidate we DID gather
        // (e.g. SerpApi web-image hits that turn out to be hotlink-protected /
        // 403, as happens for apps like Spotify) failed to download - fall back
        // to the thum.io render of this cask formulae.brew.sh page. That
        // service reliably returns a real image, so the Screenshots tab shows
        // something representative instead of staying blank. Skip when the
        // candidates we just tried WERE already that thumbnail, so we never loop
        // on a genuinely unreachable render service.
        if localURLs.isEmpty,
           let brewShot = Self.homebrewPageThumbnailURL(forCask: cask.token),
           !remoteCandidates.contains(brewShot) {
            localURLs = await cache.storeScreenshots(
                remoteURLs: [brewShot],
                token: cask.token,
                version: version
            )
            fromPagePreview = true
        }

        screenshotURLs = localURLs
        screenshotsAreHomepagePreview = fromPagePreview && !localURLs.isEmpty
    }

    // Install / uninstall now run on the shared, view-independent install
    // manager in AppDataService (see startInstall/startUninstall). That manager
    // owns the brew stream, so the operation keeps running even if the user
    // navigates away from this detail page mid-install. These methods just kick
    // the operation off; live progress is observed via
    // AppDataService.installProgress[token] (see installState(from:) below) and
    // the installed flags are re-synced from the shared state on each load.
    func startInstall(appData: AppDataService) {
        // Belt-and-suspenders: the Install/Update button is the only caller, but
        // guard against re-entry. An already-installed, up-to-date app has
        // nothing to install or upgrade — do nothing rather than re-running brew.
        guard !(isInstalled && !isOutdated) else { return }
        let upgrade = isInstalled && isOutdated
        // Gate on the session admin password first (prompt once per session via
        // the sheet, reuse after, cancel aborts), then hand it to the shared
        // manager. Without this up-front gate the operation would stall at
        // "Waiting for admin password…" for casks that need root.
        Task {
            guard let password = await appData.ensureSessionSudoPassword(
                verb: upgrade ? "update" : "install", subject: cask.displayName
            ) else { return }
            appData.startInstall(token: cask.token, isUpgrade: upgrade, sudoPassword: password)
        }
    }

    func startUninstall(appData: AppDataService) {
        // Belt-and-suspenders: only the (installed-only) Uninstall button calls
        // this, but never try to uninstall something that isn't installed.
        guard isInstalled else { return }
        // Gate on the session admin password first (same as install), then route
        // through the shared manager. The detail page's Uninstall button does a
        // plain uninstall; the deeper --zap "clean uninstall" lives on the
        // Installed list's per-app button.
        Task {
            guard let password = await appData.ensureSessionSudoPassword(
                verb: "remove", subject: cask.displayName
            ) else { return }
            appData.startUninstall(token: cask.token, zap: false, sudoPassword: password)
        }
    }

    // Pulls this cask's installed status from the shared state. Called after a
    // load and whenever the shared installed set may have changed.
    func syncInstalledState(from appData: AppDataService) {
        if let pkg = appData.installedByToken[cask.token] {
            isInstalled = true
            installedVersion = pkg.installedVersion
            isOutdated = pkg.isOutdated
        } else {
            // Guard against a launch race: while the installed set is still
            // being built (isLoadingInstalled) and is empty, do NOT clobber the
            // value we already loaded from the DB with a premature "false".
            // Once the refresh finishes, .onChange re-syncs with the real set,
            // so an app that was genuinely uninstalled still flips correctly.
            if appData.isLoadingInstalled && appData.installedByToken.isEmpty {
                return
            }
            isInstalled = false
            installedVersion = nil
            isOutdated = false
        }
    }

    // Checks whether THIS cask, if installed, is at risk from the upcoming
    // Homebrew cask-quarantine change (fails Gatekeeper and still carries the
    // quarantine flag). Sets trustRisk so the detail view can show its banner.
    // A no-op for casks that aren't installed — there is no bundle to assess.
    func checkTrust(cli: BrewCLIService) async {
        guard isInstalled else { trustRisk = nil; return }
        trustChecking = true
        trustRisk = await cli.gatekeeperRisk(forToken: cask.token)
        trustChecking = false
    }

    // Clears the quarantine flag on this app (xattr -d com.apple.quarantine via
    // removeQuarantine(at:)) so macOS will let it open. On success we drop the
    // banner and briefly show a "Trusted" confirmation; on failure we leave the
    // banner up so the user can retry.
    func trustThisApp(cli: BrewCLIService) async {
        guard let risk = trustRisk else { return }
        trusting = true
        let ok = await cli.removeQuarantine(at: risk.appPath)
        trusting = false
        if ok {
            trustRisk = nil
            trustJustCleared = true
        }
    }

    // Maps the shared manager's per-token progress onto this view's existing
    // InstallState enum so the HUD and button can keep using it unchanged.
    // Returns .idle when there's no active/recent operation for this cask.
    func installState(from appData: AppDataService) -> InstallState {
        guard let progress = appData.installProgress[cask.token] else { return .idle }
        switch progress.phase {
        case .preparing, .needsPassword, .downloading, .verifying,
             .installing, .removingOld, .cleaningUp:
            return .installing
        case .uninstalling:
            return .uninstalling
        case .finished:
            return isInstalled ? .installed : .idle
        case .failed(let message):
            return .error(message)
        }
    }

    // The live log for this cask's in-flight/just-finished operation, from the
    // shared manager. Empty when there's no operation.
    func installLog(from appData: AppDataService) -> [String] {
        appData.installProgress[cask.token]?.log ?? []
    }

    func copyInstallCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("brew install --cask \(cask.token)", forType: .string)
        didCopyCommand = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyCommand = false
        }
    }

    func resetState() {
        installLog = []
        installState = .idle
    }

    // The canonical Homebrew listing page for a cask or formula on
    // formulae.brew.sh. Casks live under `/cask/<token>`, formulae under
    // `/formula/<token>`. The token is percent-encoded defensively though Homebrew tokens are
    // already URL-safe (lowercased, hyphenated).
    static func homebrewPageURL(forCask token: String) -> URL? {
        homebrewPageURL(token: token, segment: "cask")
    }

    static func homebrewPageURL(forFormula token: String) -> URL? {
        homebrewPageURL(token: token, segment: "formula")
    }

    private static func homebrewPageURL(token: String, segment: String) -> URL? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? trimmed
        return URL(string: "https://formulae.brew.sh/\(segment)/\(encoded)")
    }

    // A screenshot-thumbnail image of this cask/formula's formulae.brew.sh page,
    // rendered by a public screenshot service. Used as the LAST-resort visual on
    // the Screenshots tab when neither real app screenshots nor a GitHub social
    // preview exist — so the tab always shows *something* representative of the
    // package rather than only text. Width is capped for a crisp card-sized
    // image. Returns nil if no Homebrew page URL can be formed.
    static func homebrewPageThumbnailURL(forCask token: String) -> URL? {
        homebrewPageThumbnailURL(pageURL: homebrewPageURL(forCask: token))
    }

    static func homebrewPageThumbnailURL(forFormula token: String) -> URL? {
        homebrewPageThumbnailURL(pageURL: homebrewPageURL(forFormula: token))
    }

    // A rendered snapshot of the app/tool's OWN homepage, used as a visual
    // fallback on the Screenshots tab when no real screenshots exist. Most
    // packages (especially CLI formulae) publish no screenshots but DO have a
    // homepage, so this gives the tab something representative. Returns nil for
    // a missing/invalid homepage or a non-web scheme.
    static func homepageThumbnailURL(homepage: String?) -> URL? {
        guard let homepage = homepage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !homepage.isEmpty,
              let url = URL(string: homepage),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return homebrewPageThumbnailURL(pageURL: url)
    }

    private static func homebrewPageThumbnailURL(pageURL: URL?) -> URL? {
        guard let pageURL else { return nil }
        // thum.io renders a screenshot of any public URL and returns the image
        // bytes directly (no API key, no JSON). The target URL is appended
        // raw after the option path segments — thum.io treats everything after
        // the last option as the URL, so it must NOT be percent-encoded.
        //   width/1200  — crisp card-sized capture
        //   png         — a real raster (not the animated default) our cache
        //                 downloader + downscaler can persist like any shot
        //   noanimate   — wait for the page to settle, then capture once
        let target = pageURL.absoluteString
        return URL(string: "https://image.thum.io/get/width/1200/png/noanimate/\(target)")
    }

    // GitHub's Open Graph social-preview image for a repo. This is the banner
    // shown when a repo link is shared; it exists for essentially every repo,
    // making it a reliable last-resort "screenshot" when no real ones are found.
    static func socialPreviewURL(for repoURL: URL?) -> URL? {
        guard let repoURL else { return nil }
        let parts = repoURL.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1]
        return URL(string: "https://opengraph.githubassets.com/1/\(owner)/\(repo)")
    }

    // A best-effort link to the English Wikipedia article for a name, used as
    // the More Info footer link when the long-form content is a Wikipedia
    // article rather than a README. Wikipedia resolves spaces/redirects, so the
    // simple /wiki/<Name> form lands on (or redirects to) the right page.
    static func wikipediaArticleURL(for name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let slug = trimmed.replacingOccurrences(of: " ", with: "_")
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://en.wikipedia.org/wiki/\(encoded)")
    }

    // A human-readable "about" blurb for the screenshots-tab text fallback,
    // used only when no image at all could be shown. Prefers the GitHub README
    // intro (first real prose, with images/badges/headings/HTML stripped) and
    // falls back to the cask's own Homebrew description.
    var aboutText: String? {
        if let md = readme, let intro = Self.readmeIntro(from: md), !intro.isEmpty {
            return intro
        }
        let desc = (cask.desc ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return desc.isEmpty ? nil : desc
    }

    // Extracts the first meaningful paragraph(s) of prose from a README,
    // skipping image lines, badge shields, HTML tags, headings, and code
    // fences. Returns up to ~600 characters of plain text.
    static func readmeIntro(from markdown: String) -> String? {
        var collected: [String] = []
        var inFence = false
        var charCount = 0

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Toggle fenced code blocks and skip their contents.
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            if line.isEmpty {
                // Paragraph break — stop once we already have some prose.
                if !collected.isEmpty { break }
                continue
            }
            // Skip headings, image lines, badge/HTML-only lines, blockquotes,
            // horizontal rules, and table rows.
            let lower = line.lowercased()
            if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("---")
                || line.hasPrefix("===") || line.hasPrefix("|")
                || line.hasPrefix("![") || line.hasPrefix("<") {
                continue
            }
            if lower.contains("shields.io") || lower.contains("badge") {
                continue
            }

            // Skip lines that are predominantly link/image markup — badge
            // clusters and reference-style shields like
            // "[![][license img]][license] [![][licensemit img]][licensemit]"
            // that the simple prefix checks above don't catch (they start with
            // "[" not "!["). If stripping all markup removes most of the line,
            // it's decoration, not prose.
            if Self.isMarkupDecorationLine(line) { continue }

            // Strip inline Markdown/HTML noise from a prose line.
            var clean = line
            // Reference-style linked image badges: [![alt][ref]][ref2] -> drop.
            clean = clean.replacingOccurrences(
                of: #"\[!\[[^\]]*\]\[[^\]]*\]\](\[[^\]]*\]|\([^)]*\))?"#, with: "", options: .regularExpression)
            // Inline linked image badges: [![alt](url)](url) -> drop.
            clean = clean.replacingOccurrences(
                of: #"\[!\[[^\]]*\]\([^)]*\)\]\([^)]*\)"#, with: "", options: .regularExpression)
            // Inline images ![alt](url) and ![alt][ref] -> remove entirely.
            clean = clean.replacingOccurrences(
                of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            clean = clean.replacingOccurrences(
                of: #"!\[[^\]]*\]\[[^\]]*\]"#, with: "", options: .regularExpression)
            // Links [text](url) and [text][ref] -> keep the visible text.
            clean = clean.replacingOccurrences(
                of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            clean = clean.replacingOccurrences(
                of: #"\[([^\]]*)\]\[[^\]]*\]"#, with: "$1", options: .regularExpression)
            // Any leftover HTML tags.
            clean = clean.replacingOccurrences(
                of: #"<[^>]+>"#, with: "", options: .regularExpression)
            // Emphasis / inline-code markers.
            clean = clean.replacingOccurrences(of: "**", with: "")
            clean = clean.replacingOccurrences(of: "`", with: "")
            clean = clean.trimmingCharacters(in: .whitespaces)

            guard !clean.isEmpty else { continue }
            collected.append(clean)
            charCount += clean.count
            if charCount >= 600 { break }
        }

        guard !collected.isEmpty else { return nil }
        var text = collected.joined(separator: " ")
        if text.count > 600 {
            let idx = text.index(text.startIndex, offsetBy: 600)
            text = String(text[..<idx]).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        return text
    }

    // True when a README line is mostly Markdown link/image markup (badge rows,
    // logo banners, reference-style shields) rather than prose. We strip every
    // []()/![]/<> construct and, if that removes most of the line OR leaves no
    // real words, treat the line as decoration to skip.
    static func isMarkupDecorationLine(_ line: String) -> Bool {
        var stripped = line
        let patterns = [
            #"!\[[^\]]*\]\([^)]*\)"#,           // ![alt](url)
            #"!\[[^\]]*\]\[[^\]]*\]"#,          // ![alt][ref]
            #"\[!\[.*?\]\(.*?\)\]\(.*?\)"#,     // [![..](..)](..)
            #"\[!\[.*?\]\[.*?\]\]\[.*?\]"#,     // [![][ref]][ref]
            #"\[!\[.*?\]\[.*?\]\]\(.*?\)"#,     // [![][ref]](url)
            #"\[([^\]]*)\]\([^)]*\)"#,          // [text](url)
            #"\[([^\]]*)\]\[[^\]]*\]"#,         // [text][ref]
            #"<[^>]+>"#                         // html tags
        ]
        for pat in patterns {
            stripped = stripped.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
        }
        stripped = stripped.replacingOccurrences(of: #"[\[\]\(\)]"#, with: " ", options: .regularExpression)
        stripped = stripped.trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty { return true }
        let original = line.trimmingCharacters(in: .whitespaces)
        // If more than ~45% of the line was markup, it's decoration.
        if !original.isEmpty {
            let removed = Double(original.count - stripped.count) / Double(original.count)
            if removed > 0.45 { return true }
        }
        // Needs at least a few real letters to count as prose.
        let letters = stripped.filter { $0.isLetter }.count
        return letters < 12
    }

    // Parses image references out of a GitHub README (both Markdown
    // ![alt](url) and HTML <img src="url">), resolving relative paths
    // against the repo's raw content base, and keeps only image files.
    static func extractScreenshotURLs(from markdown: String, repoURL: URL) -> [URL] {
        // Derive "owner/repo" from a https://github.com/owner/repo URL.
        let parts = repoURL.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return [] }
        let owner = parts[0]
        let repo = parts[1]
        let rawBase = "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/"

        var candidates: [String] = []

        // Markdown image syntax: ![alt](url) — url may have a title after a space.
        if let mdRegex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*([^)\s]+)"#) {
            let range = NSRange(markdown.startIndex..., in: markdown)
            for match in mdRegex.matches(in: markdown, range: range) {
                if let r = Range(match.range(at: 1), in: markdown) {
                    candidates.append(String(markdown[r]))
                }
            }
        }

        // HTML <img src="url"> (single or double quoted).
        if let htmlRegex = try? NSRegularExpression(pattern: #"(?i)<img[^>]*\bsrc\s*=\s*["']([^"']+)["']"#) {
            let range = NSRange(markdown.startIndex..., in: markdown)
            for match in htmlRegex.matches(in: markdown, range: range) {
                if let r = Range(match.range(at: 1), in: markdown) {
                    candidates.append(String(markdown[r]))
                }
            }
        }

        let imageExts = ["png", "jpg", "jpeg", "gif", "webp"]
        var seen = Set<String>()
        var result: [URL] = []

        for raw in candidates {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip a wrapping <...> if present and any angle brackets.
            s = s.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
            guard !s.isEmpty else { continue }

            // Skip badges/shields which are decorative, not screenshots.
            let lower = s.lowercased()
            if lower.contains("shields.io") || lower.contains("badge") || lower.contains("travis-ci")
                || lower.contains("circleci") || lower.contains("codecov") || lower.contains("/badges/") {
                continue
            }

            // Resolve to an absolute URL.
            let absolute: String
            if s.hasPrefix("http://") || s.hasPrefix("https://") {
                absolute = s
            } else if s.hasPrefix("//") {
                absolute = "https:" + s
            } else {
                let relative = s.hasPrefix("/") ? String(s.dropFirst()) : s
                absolute = rawBase + relative
            }

            // GitHub "blob" links point at the HTML page, not the raw image;
            // rewrite them to the raw host so AsyncImage can load the bytes.
            // NOTE: user-attachments URLs are NOT rewritten — they're already a
            // direct asset endpoint and "/blob/" rewriting would corrupt them.
            let normalized: String
            if absolute.contains("github.com/user-attachments/") {
                normalized = absolute
            } else {
                normalized = absolute
                    .replacingOccurrences(of: "https://github.com/", with: "https://raw.githubusercontent.com/")
                    .replacingOccurrences(of: "/blob/", with: "/")
            }

            // Decide whether this is an image. Most images carry a recognized
            // extension, but GitHub's modern attachment hosts serve screenshots
            // with NO extension (e.g. github.com/user-attachments/assets/<uuid>,
            // user-images.githubusercontent.com/..., camo.githubusercontent.com/...).
            // Accept those hosts as images so real screenshots aren't dropped.
            let lowerNorm = normalized.lowercased()
            let isExtensionlessImageHost =
                lowerNorm.contains("github.com/user-attachments/")
                || lowerNorm.contains("user-images.githubusercontent.com")
                || lowerNorm.contains("camo.githubusercontent.com")

            let pathPart = normalized.split(separator: "?").first.map(String.init) ?? normalized
            let ext = (pathPart as NSString).pathExtension.lowercased()
            guard imageExts.contains(ext) || isExtensionlessImageHost else { continue }

            guard let u = URL(string: normalized) else { continue }
            if seen.insert(normalized).inserted {
                result.append(u)
            }
        }

        return result
    }

}
