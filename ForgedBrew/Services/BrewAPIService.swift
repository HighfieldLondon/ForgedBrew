import Foundation

// MARK: - BrewAPIService
//
// All read-only network access to Homebrew's public JSON API (formulae.brew.sh)
// plus the third-party enrichment sources the detail view layers on top:
// GitHub (stars / license / README / last-commit date / repo search), ghcr.io
// (bottle download sizes), Wikipedia (About blurbs + full articles), SerpApi
// (screenshot image search), and arbitrary homepage HTML (<head> metadata).
//
// Design constraints that shape almost everything here:
//   • Rate limits. The unauthenticated GitHub API allows only ~60 core req/hr
//     and ~10 search req/min. Several layers of caching (in-memory TTL caches, a
//     disk-backed catalog-date cache, and a self-imposed request budget) keep us
//     well under those caps so a session never gets 403'd.
//   • Best-effort enrichment. Every method beyond the core catalog fetch returns
//     nil / [] on any failure rather than throwing — enrichment must never break
//     the detail view. Confident "misses" are cached too, so we don't re-spend a
//     scarce request on a result we already know is empty.
//   • Caching correctness. The session is cache-FIRST (right for the big, slow-
//     changing catalog) but per-package dynamic data (version, license, install
//     counts) passes .reloadRevalidatingCacheData so a reopened detail view
//     isn't stuck on a stale copy.

// Errors thrown by the core (throwing) catalog/detail fetches. The many
// best-effort enrichment methods don't throw — they map failures to nil/[].
enum BrewAPIError: Error, Sendable {
    case networkError(Error)
    case decodingError(Error)
    case rateLimited
    case notFound
    case invalidURL
}

private nonisolated struct GitHubRepo: Codable, Sendable {
    let stargazersCount: Int
    let description: String?
    let license: GitHubLicense?

    enum CodingKeys: String, CodingKey {
        case stargazersCount = "stargazers_count"
        case description
        case license
    }
}

// GitHub's `license` object on a repo. We want the SPDX id (e.g. "MIT",
// "GPL-3.0", "Apache-2.0") as the canonical, displayable license token, with
// the human name as a fallback. GitHub sends "NOASSERTION" for repos whose
// license it can't confidently classify — we treat that as unknown.
private nonisolated struct GitHubLicense: Codable, Sendable {
    let spdxId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case spdxId = "spdx_id"
        case name
    }
}

private nonisolated struct GitHubReadme: Codable, Sendable {
    let content: String
    let encoding: String
}

// Minimal shape of a per-cask JSON response — we only need the download
// URL of the artifact (.dmg/.zip/.pkg) so we can probe its size over the
// network for apps that are not installed locally.
private nonisolated struct CaskDownloadInfo: Codable, Sendable {
    let url: String?
}

// Minimal shape of a per-formula JSON response's bottle section. Homebrew
// publishes no size, but it lists one bottle artifact per platform tag
// (e.g. "arm64_tahoe", "sonoma"). We pick the tag matching this Mac and probe
// that bottle's download size. Bottles are hosted on ghcr.io, which requires
// an anonymous OAuth bearer token before the blob length is readable.
private nonisolated struct FormulaBottleFile: Codable, Sendable {
    let url: String?
}
private nonisolated struct FormulaBottleStable: Codable, Sendable {
    let files: [String: FormulaBottleFile]?
}
private nonisolated struct FormulaBottle: Codable, Sendable {
    let stable: FormulaBottleStable?
}
private nonisolated struct FormulaBottleInfo: Codable, Sendable {
    let bottle: FormulaBottle?
}

// Token response from ghcr.io/token for anonymous (pull-only) blob access.
private nonisolated struct GHCRToken: Codable, Sendable {
    let token: String?
}

// Minimal shape of a /search/repositories result item — we only need the
// owner/repo (full_name), the repo's declared homepage (the strong match
// signal), and stars to break ties.
private nonisolated struct GitHubSearchResponse: Codable, Sendable {
    let items: [GitHubSearchItem]
}

private nonisolated struct GitHubSearchItem: Codable, Sendable {
    let fullName: String
    let homepage: String?
    let stargazersCount: Int

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case homepage
        case stargazersCount = "stargazers_count"
    }
}

// Minimal shape of a SerpApi Google Images response. We only need each result's
// directly-loadable full-size image URL (original) plus its dimensions so we
// can prefer landscape, screenshot-shaped images over tiny thumbnails or square
// logos. SerpApi returns these fields in snake_case (original_width/height),
// which the decoder's .convertFromSnakeCase strategy maps to these camelCase
// properties automatically.
private nonisolated struct SerpImageSearchResponse: Codable, Sendable {
    let imagesResults: [SerpImageResult]?
}

private nonisolated struct SerpImageResult: Codable, Sendable {
    let original: String?
    let originalWidth: Int?
    let originalHeight: Int?
    let title: String?
    let source: String?
}

// Minimal decode of the GitHub commits endpoint
// (/repos/<owner>/<repo>/commits?path=<file>&per_page=1). We read only the most
// recent commit's date, which is the real "last updated in the Homebrew
// catalog" timestamp for that formula/cask .rb file.
private nonisolated struct GitHubCommitEntry: Codable, Sendable {
    let commit: GitHubCommitDetail
}
private nonisolated struct GitHubCommitDetail: Codable, Sendable {
    let committer: GitHubCommitActor?
    let author: GitHubCommitActor?
}
private nonisolated struct GitHubCommitActor: Codable, Sendable {
    let date: String?
}

actor BrewAPIService {
    static let shared = BrewAPIService()

    private let session: URLSession
    private let decoder: JSONDecoder
    private var githubRequestCount: Int = 0
    private var githubWindowStart: Date = Date()
    private let githubRateLimit = 50

    // Per-repo cache for GitHub detail data (keyed by "owner/repo"). Repeat
    // detail-view opens within the TTL cost 0 GitHub requests, protecting the
    // unauthenticated 60 req/hr cap. The full repo object (stars + license +
    // description) is cached once, so stars and license are served from a
    // SINGLE /repos request — fetching the license costs no extra call. README
    // is cached separately (different endpoint).
    private var githubRepoCache: [String: (value: GitHubRepo, fetchedAt: Date)] = [:]
    // In-memory cache of "catalog last updated" dates, keyed by a stable id
    // ("cask/<token>" or "formula/<name>"). Backed by a small JSON file on disk
    // (see catalogDateDiskCache) so the date survives relaunches and we don't
    // re-spend the scarce GitHub request budget. nil is cached too, so a
    // confident "no date" (e.g. file path 404) is remembered for the TTL.
    private var catalogDateCache: [String: (value: Date?, fetchedAt: Date)] = [:]
    // Catalog files change at most a few times a week per package, so a long
    // TTL keeps GitHub calls rare. 7 days.
    private let catalogDateTTL: TimeInterval = 7 * 24 * 3600
    private var catalogDiskLoaded = false
    private var githubReadmeCache: [String: (value: String, fetchedAt: Date)] = [:]
    // Cache for Wikipedia "about" blurbs (closed-source apps with no repo).
    // Keyed by the lowercased search title; value may be nil (no article) so
    // a miss isn't re-fetched every time the About tab opens.
    private var aboutBlurbCache: [String: (value: String?, fetchedAt: Date)] = [:]
    // Cache for homepage HTML metadata (title / meta description / og:image),
    // keyed by the lowercased homepage URL. Value may be nil so a confident
    // miss (no usable meta) is remembered for the TTL and not re-fetched.
    private var homepageMetaCache: [String: (value: HomepageMeta?, fetchedAt: Date)] = [:]
    // Cache for GitHub-wiki Home-page blurbs, keyed by "owner/repo". nil cached.
    private var githubWikiCache: [String: (value: String?, fetchedAt: Date)] = [:]
    // Cache for FULL Wikipedia article text (More Info long-form fallback),
    // keyed by lowercased query. nil cached so a miss isn't re-fetched.
    private var wikiFullArticleCache: [String: (value: String?, fetchedAt: Date)] = [:]
    private let githubCacheTTL: TimeInterval = 3600

    // Per-cask-token cache for discovered repo URLs (via GitHub repo search,
    // used only when a cask's homepage isn't itself a github.com URL). We cache
    // the optional result so a confident "no match" is remembered too and we
    // don't re-spend a scarce search request. GitHub's UNAUTHENTICATED search
    // endpoint is rate-limited to ~10 req/min, separate from the 60/hr core
    // cap, so we guard it with its own short window.
    private var githubRepoSearchCache: [String: (value: URL?, fetchedAt: Date)] = [:]
    private var githubSearchCount: Int = 0
    private var githubSearchWindowStart: Date = Date()
    private let githubSearchLimit = 8   // stay safely under the ~10/min cap

    private func cacheKey(owner: String, repo: String) -> String {
        "\(owner)/\(repo)"
    }

    // Stores a value in one of the (value:, fetchedAt:) TTL caches and bounds its
    // size: when the entry count exceeds `cap`, the oldest entries (by fetchedAt)
    // are evicted down to `cap`. Without this the per-session text caches (README
    // bodies, full Wikipedia articles) grow unbounded as the user opens more
    // packages, since entries were only ever TTL-checked on read, never removed.
    private func storeCapped<V>(_ value: V,
                                forKey key: String,
                                in cache: inout [String: (value: V, fetchedAt: Date)],
                                cap: Int) {
        cache[key] = (value, Date())
        guard cache.count > cap else { return }
        let overflow = cache.count - cap
        let oldest = cache.sorted { $0.value.fetchedAt < $1.value.fetchedAt }.prefix(overflow)
        for (k, _) in oldest { cache.removeValue(forKey: k) }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "ForgedBrew/1.0"]
        config.urlCache = URLCache(
            memoryCapacity: 10 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        // Without explicit timeouts every call inherits the 60s default, so the
        // ~15 MB catalog fetch or a stalled GitHub call could hang for a full
        // minute on a flaky network. Bound per-request waits tightly; allow the
        // large catalog resource a more generous overall ceiling.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)

        let dec = JSONDecoder()
        // Models already use explicit CodingKeys; this is a safe fallback
        // for any future fields that arrive in snake_case.
        dec.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = dec
    }

    // Generic JSON GET. `cachePolicy` overrides the session default
    // (.returnCacheDataElseLoad) per request. The session default is cache-FIRST,
    // which is right for the big, slow-changing catalog but serves stale data for
    // dynamic endpoints (analytics counts, GitHub stars, per-package license /
    // version / dates). Those callers pass .reloadRevalidatingCacheData so the
    // cached copy is revalidated against the origin (a cheap conditional GET that
    // returns 304 when unchanged) instead of being trusted indefinitely.
    private func fetch<T: Decodable>(
        _ url: URL,
        cachePolicy: URLRequest.CachePolicy? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        if let cachePolicy { request.cachePolicy = cachePolicy }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BrewAPIError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                throw BrewAPIError.notFound
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                throw BrewAPIError.rateLimited
            }
            guard (200..<300).contains(http.statusCode) else {
                throw BrewAPIError.networkError(
                    NSError(domain: "BrewAPI", code: http.statusCode)
                )
            }
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BrewAPIError.decodingError(error)
        }
    }

    private func checkGitHubRateLimit() throws {
        let now = Date()
        if now.timeIntervalSince(githubWindowStart) > 3600 {
            githubRequestCount = 0
            githubWindowStart = now
        }
        if githubRequestCount >= githubRateLimit {
            throw BrewAPIError.rateLimited
        }
        githubRequestCount += 1
    }

    // Splits a github.com/<owner>/<repo>/… URL into its owner and repo
    // components (the first two non-"/" path segments). Returns nil when the URL
    // has too few path components to be a repo URL.
    private func extractOwnerRepo(from repoURL: URL) -> (owner: String, repo: String)? {
        let parts = repoURL.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    // MARK: - Catalog (casks & formulae)

    func fetchAllCasks() async throws -> [CaskMetadata] {
        guard let url = URL(string: "https://formulae.brew.sh/api/cask.json") else {
            throw BrewAPIError.invalidURL
        }
        return try await fetch(url)
    }

    // Conditional full-cask pull. Sends If-None-Match with the supplied
    // ETag; on 304 Not Modified returns (nil, etag) so the caller can skip
    // the ~15 MB JSON parse and DB rewrite entirely. On 200 returns the
    // freshly decoded casks plus the new ETag (if the server sent one).
    func fetchAllCasksConditional(
        etag: String?
    ) async throws -> (casks: [CaskMetadata]?, etag: String?) {
        guard let url = URL(string: "https://formulae.brew.sh/api/cask.json") else {
            throw BrewAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BrewAPIError.networkError(error)
        }

        let http = response as? HTTPURLResponse
        let newETag = http?.value(forHTTPHeaderField: "Etag")

        if let http {
            if http.statusCode == 304 {
                // Not modified — keep existing DB rows, reuse old ETag.
                return (nil, etag)
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                throw BrewAPIError.rateLimited
            }
            guard (200..<300).contains(http.statusCode) else {
                throw BrewAPIError.networkError(
                    NSError(domain: "BrewAPI", code: http.statusCode)
                )
            }
        }

        do {
            let casks = try decoder.decode([CaskMetadata].self, from: data)
            return (casks, newETag ?? etag)
        } catch {
            throw BrewAPIError.decodingError(error)
        }
    }

    func fetchCask(token: String) async throws -> CaskMetadata {
        guard let url = URL(string: "https://formulae.brew.sh/api/cask/\(token).json") else {
            throw BrewAPIError.invalidURL
        }
        // Per-cask version/license/dates shown in the detail view change on each
        // release — revalidate so a reopened detail view isn't stuck on an old
        // cached copy. Cheap: a 304 when nothing changed.
        return try await fetch(url, cachePolicy: .reloadRevalidatingCacheData)
    }

    // Probe the *download* size (bytes) of a cask's primary artifact for
    // apps that are not installed locally. Homebrew's API does not publish a
    // size field, so we fetch the per-cask JSON to learn the artifact URL,
    // then ask the host for its length. We try a 1-byte ranged GET first and
    // read the total from Content-Range (most reliable across CDNs/redirects),
    // falling back to a HEAD request's Content-Length. Returns nil on any
    // failure — size is best-effort and must never break the detail view.
    func fetchDownloadSize(token: String) async -> Int64? {
        guard let metaURL = URL(
            string: "https://formulae.brew.sh/api/cask/\(token).json"
        ) else { return nil }

        // 1. Learn the artifact URL from the per-cask JSON.
        let info: CaskDownloadInfo
        do {
            info = try await fetch(metaURL)
        } catch {
            return nil
        }
        guard
            let urlString = info.url,
            let artifactURL = URL(string: urlString)
        else { return nil }

        // 2. Ranged GET — read total from Content-Range "bytes 0-0/<total>".
        if let total = await rangedContentLength(artifactURL) {
            return total
        }

        // 3. Fallback — HEAD request Content-Length.
        return await headContentLength(artifactURL)
    }

    private func rangedContentLength(_ url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard
            let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else { return nil }

        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/") {
            let totalPart = range[range.index(after: slash)...]
            if let total = Int64(totalPart.trimmingCharacters(in: .whitespaces)),
               total > 0 {
                return total
            }
        }
        // Some hosts ignore Range and return the whole length here.
        if http.statusCode == 200 {
            let len = http.expectedContentLength
            return len > 0 ? len : nil
        }
        return nil
    }

    private func headContentLength(_ url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        guard
            let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else { return nil }
        let len = http.expectedContentLength
        return len > 0 ? len : nil
    }

    func fetchAllFormulas() async throws -> [FormulaMetadata] {
        guard let url = URL(string: "https://formulae.brew.sh/api/formula.json") else {
            throw BrewAPIError.invalidURL
        }
        // NOTE: do NOT route this through the shared `fetch(_:)` helper. That
        // helper's decoder uses `.convertFromSnakeCase`, which rewrites JSON
        // keys to camelCase BEFORE matching CodingKeys. FormulaMetadata already
        // declares explicit snake_case CodingKeys (full_name, build_dependencies,
        // install_count_30d), so the conversion makes the decoder look for a key
        // named "full_name" that no longer exists -> keyNotFound on the required
        // `fullName` field -> the whole catalog fails to decode and nothing is
        // saved. Casks survive the same decoder only because their snake_case
        // fields are all optional (decodeIfPresent). Decode formulae with a plain
        // decoder so the explicit CodingKeys match the raw JSON keys directly.
        var request = URLRequest(url: url)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BrewAPIError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw BrewAPIError.notFound }
            if http.statusCode == 403 || http.statusCode == 429 { throw BrewAPIError.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                throw BrewAPIError.networkError(NSError(domain: "BrewAPI", code: http.statusCode))
            }
        }

        do {
            return try JSONDecoder().decode([FormulaMetadata].self, from: data)
        } catch {
            throw BrewAPIError.decodingError(error)
        }
    }

    // Conditional full-formula pull. Mirrors fetchAllCasksConditional: sends
    // If-None-Match with the supplied ETag and on 304 Not Modified returns
    // (nil, etag) so the caller can skip the large formula.json parse + DB
    // rewrite entirely. Uses a PLAIN decoder for the same reason fetchAllFormulas
    // does (FormulaMetadata's explicit snake_case CodingKeys must match the raw
    // JSON keys, which the shared .convertFromSnakeCase decoder would break).
    func fetchAllFormulasConditional(
        etag: String?
    ) async throws -> (formulas: [FormulaMetadata]?, etag: String?) {
        guard let url = URL(string: "https://formulae.brew.sh/api/formula.json") else {
            throw BrewAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BrewAPIError.networkError(error)
        }

        let http = response as? HTTPURLResponse
        let newETag = http?.value(forHTTPHeaderField: "Etag")

        if let http {
            if http.statusCode == 304 {
                // Not modified — keep existing DB rows, reuse old ETag.
                return (nil, etag)
            }
            if http.statusCode == 404 { throw BrewAPIError.notFound }
            if http.statusCode == 403 || http.statusCode == 429 {
                throw BrewAPIError.rateLimited
            }
            guard (200..<300).contains(http.statusCode) else {
                throw BrewAPIError.networkError(
                    NSError(domain: "BrewAPI", code: http.statusCode)
                )
            }
        }

        do {
            let formulas = try JSONDecoder().decode([FormulaMetadata].self, from: data)
            return (formulas, newETag ?? etag)
        } catch {
            throw BrewAPIError.decodingError(error)
        }
    }

    // Single-formula detail fetch. The lightweight catalog cache (formulas table)
    // doesn't store dependencies or the HEAD version, so the detail page lazily
    // calls this to enrich what it shows. Like fetchAllFormulas, this uses a
    // plain JSONDecoder (NOT the shared `fetch(_:)` helper) because
    // FormulaMetadata declares explicit snake_case CodingKeys that conflict with
    // the shared decoder's .convertFromSnakeCase strategy.
    func fetchFormula(name: String) async throws -> FormulaMetadata {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "https://formulae.brew.sh/api/formula/\(encoded).json") else {
            throw BrewAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        // Per-formula version/license/dates change on each release; revalidate
        // rather than inherit the session's cache-first default (which would
        // serve an indefinitely-stale copy in the detail view). Cheap 304 when
        // unchanged.
        request.cachePolicy = .reloadRevalidatingCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BrewAPIError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw BrewAPIError.notFound }
            if http.statusCode == 403 || http.statusCode == 429 { throw BrewAPIError.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                throw BrewAPIError.networkError(NSError(domain: "BrewAPI", code: http.statusCode))
            }
        }

        do {
            return try JSONDecoder().decode(FormulaMetadata.self, from: data)
        } catch {
            throw BrewAPIError.decodingError(error)
        }
    }

    // Probe the *bottle download* size (bytes) of a formula for apps that are
    // not installed locally. Homebrew publishes no size, so we fetch the
    // per-formula JSON, pick the bottle artifact matching THIS Mac (arch +
    // macOS codename, e.g. "arm64_tahoe"), then read its length from ghcr.io.
    // ghcr.io blobs need an anonymous OAuth bearer token first, after which a
    // HEAD (URLSession auto-follows the 307 to the CDN) yields Content-Length.
    // Returns nil on any failure — size is best-effort and must never break the
    // detail view. Note: this is the *compressed* bottle size, not the
    // extracted on-disk footprint (installed formulae show the real du size).
    func fetchBottleSize(name: String) async -> Int64? {
        let encoded = name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? name
        guard let metaURL = URL(
            string: "https://formulae.brew.sh/api/formula/\(encoded).json"
        ) else { return nil }

        // 1. Learn the bottle artifact URL for this Mac's platform tag.
        let info: FormulaBottleInfo
        do {
            info = try await fetch(metaURL)
        } catch {
            return nil
        }
        guard let files = info.bottle?.stable?.files, !files.isEmpty else {
            return nil
        }
        // Prefer this Mac's exact tag; otherwise fall back to any arm64/Intel
        // macOS bottle so we still show *a* representative size rather than "—".
        let tag = Self.currentBottleTag()
        let chosen: FormulaBottleFile? =
            files[tag]
            ?? files.first(where: { $0.key.hasPrefix("arm64_") && !$0.key.contains("linux") })?.value
            ?? files.first(where: { !$0.key.contains("linux") })?.value
        guard
            let urlString = chosen?.url,
            let blobURL = URL(string: urlString)
        else { return nil }

        // 2. ghcr.io blobs require an anonymous pull token scoped to the repo.
        //    The bottle URL looks like
        //    https://ghcr.io/v2/homebrew/core/<formula>/blobs/sha256:…
        //    so the scope repository is everything between "/v2/" and "/blobs/".
        let token = await ghcrPullToken(for: blobURL)

        // 3. HEAD the blob with the bearer token; URLSession follows the 307
        //    redirect to the actual CDN object and surfaces its Content-Length.
        var request = URLRequest(url: blobURL)
        request.httpMethod = "HEAD"
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard
            let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else { return nil }
        let len = http.expectedContentLength
        return len > 0 ? len : nil
    }

    // Fetch an anonymous (pull-only) OAuth token for a ghcr.io blob URL.
    private func ghcrPullToken(for blobURL: URL) async -> String? {
        // Path is "/v2/<repo…>/blobs/sha256:…"; the scope repo is the segment
        // list between "v2" and "blobs".
        let parts = blobURL.pathComponents.filter { $0 != "/" }
        guard
            let v2 = parts.firstIndex(of: "v2"),
            let blobs = parts.firstIndex(of: "blobs"),
            blobs > v2 + 1
        else { return nil }
        let repo = parts[(v2 + 1)..<blobs].joined(separator: "/")
        guard let tokenURL = URL(
            string: "https://ghcr.io/token?service=ghcr.io&scope=repository:\(repo):pull"
        ) else { return nil }

        var request = URLRequest(url: tokenURL)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let decoded = try? JSONDecoder().decode(GHCRToken.self, from: data)
        else { return nil }
        return decoded.token
    }

    // The Homebrew bottle platform tag for the current machine, e.g.
    // "arm64_tahoe" (Apple Silicon) or "sonoma" (Intel). Built from the running
    // macOS major version and CPU architecture. Falls back to the newest known
    // codename if the major version is newer than this table.
    nonisolated static func currentBottleTag() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let codename: String
        switch v {
        case 26...: codename = "tahoe"
        case 15:    codename = "sequoia"
        case 14:    codename = "sonoma"
        case 13:    codename = "ventura"
        case 12:    codename = "monterey"
        case 11:    codename = "big_sur"
        default:    codename = "tahoe"
        }
        #if arch(arm64)
        return "arm64_\(codename)"
        #else
        return codename
        #endif
    }

    // MARK: - Install analytics

    func fetchCaskAnalytics(period: String) async throws -> CaskAnalyticsResponse {
        let urlString = "https://formulae.brew.sh/api/analytics/cask-install/homebrew-cask/\(period).json"
        guard let url = URL(string: urlString) else {
            throw BrewAPIError.invalidURL
        }
        // Install counts change daily — revalidate rather than trust the cache.
        return try await fetch(url, cachePolicy: .reloadRevalidatingCacheData)
    }

    // Mirrors fetchCaskAnalytics for formulae. The formula analytics endpoint
    // returns a flat `items` array (ranked install counts) rather than the
    // cask endpoint's category-keyed `formulae` dictionary.
    func fetchFormulaAnalytics(period: String) async throws -> FormulaAnalyticsResponse {
        let urlString = "https://formulae.brew.sh/api/analytics/install/\(period).json"
        guard let url = URL(string: urlString) else {
            throw BrewAPIError.invalidURL
        }
        // Install counts change daily — revalidate rather than trust the cache.
        return try await fetch(url, cachePolicy: .reloadRevalidatingCacheData)
    }

    // MARK: - GitHub repo (stars / license / description)

    // Fetches (and caches) the full GitHub repo object for a repo URL. Both
    // stars and license are decoded from this one /repos response, so callers
    // for either piece of data share a single request within the TTL.
    private func fetchGitHubRepo(repoURL: URL) async throws -> GitHubRepo {
        guard let (owner, repo) = extractOwnerRepo(from: repoURL) else {
            throw BrewAPIError.invalidURL
        }
        let key = cacheKey(owner: owner, repo: repo)
        if let cached = githubRepoCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < githubCacheTTL {
            return cached.value
        }
        try checkGitHubRateLimit()
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)") else {
            throw BrewAPIError.invalidURL
        }
        // Stars/license change over time; this is only reached when our own
        // 1-hour TTL has expired, so revalidate against GitHub rather than let
        // the URL cache serve an indefinitely-stale /repos response.
        let result: GitHubRepo = try await fetch(url, cachePolicy: .reloadRevalidatingCacheData)
        storeCapped(result, forKey: key, in: &githubRepoCache, cap: 300)
        return result
    }

    // MARK: - Catalog "Last Updated" date (GitHub commit history)

    // Returns the date this package's Homebrew .rb file was last committed —
    // the honest "last updated in the catalog" signal (Homebrew's JSON API does
    // NOT expose this). `repo` is "Homebrew/homebrew-core" for formulae or
    // "Homebrew/homebrew-cask" for casks; `path` is the .rb file path inside
    // that repo (e.g. "Formula/w/wget.rb"). `id` keys the cache. Result is
    // disk-cached for catalogDateTTL so this costs a GitHub request at most once
    // per package per week, protecting the unauthenticated rate cap. Returns
    // nil on any failure (rate limited, 404, offline) — callers fall back.
    func catalogLastUpdated(repo: String, path: String, id: String) async -> Date? {
        loadCatalogDiskCacheIfNeeded()
        if let cached = catalogDateCache[id],
           Date().timeIntervalSince(cached.fetchedAt) < catalogDateTTL {
            return cached.value
        }
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.github.com/repos/\(repo)/commits?path=\(encodedPath)&per_page=1") else {
            return cacheCatalogDate(nil, id: id)
        }
        do {
            try checkGitHubRateLimit()
        } catch {
            // Out of budget for this hour — don't cache a nil (so we retry next
            // hour) and just fall back for now.
            return catalogDateCache[id]?.value
        }
        do {
            // Only reached after our disk-cached date TTL expires; revalidate so
            // the "last updated" date reflects new commits instead of a stale
            // cached commits response.
            let entries: [GitHubCommitEntry] = try await fetch(url, cachePolicy: .reloadRevalidatingCacheData)
            let iso = entries.first?.commit.committer?.date ?? entries.first?.commit.author?.date
            guard let iso, let date = Self.isoFormatter.date(from: iso) else {
                return cacheCatalogDate(nil, id: id)
            }
            return cacheCatalogDate(date, id: id)
        } catch {
            return cacheCatalogDate(nil, id: id)
        }
    }

    // ISO-8601 parser for GitHub's "2026-03-20T18:56:27Z" commit dates.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    @discardableResult
    private func cacheCatalogDate(_ date: Date?, id: String) -> Date? {
        catalogDateCache[id] = (date, Date())
        persistCatalogDiskCache()
        return date
    }

    // On-disk persistence so the dates survive relaunches. A single small JSON
    // file under Application Support. Errors are swallowed — the cache is purely
    // an optimization, never load-bearing.
    private var catalogDiskCacheURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("ForgedBrew", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog-dates.json")
    }

    private struct DiskEntry: Codable { let date: Date?; let fetchedAt: Date }

    private func loadCatalogDiskCacheIfNeeded() {
        guard !catalogDiskLoaded else { return }
        catalogDiskLoaded = true
        guard let url = catalogDiskCacheURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: DiskEntry].self, from: data) else { return }
        for (k, v) in decoded {
            catalogDateCache[k] = (v.date, v.fetchedAt)
        }
    }

    private func persistCatalogDiskCache() {
        guard let url = catalogDiskCacheURL else { return }
        let snapshot = catalogDateCache.mapValues { DiskEntry(date: $0.value, fetchedAt: $0.fetchedAt) }
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func fetchGitHubStars(repoURL: URL) async throws -> Int {
        try await fetchGitHubRepo(repoURL: repoURL).stargazersCount
    }

    // Returns the repo's declared license as a canonical SPDX id (e.g. "MIT",
    // "GPL-3.0", "Apache-2.0"). Shares the cached repo object with
    // fetchGitHubStars, so calling both for one repo costs a single request.
    // Returns nil when the repo has no detectable license, or when GitHub
    // reports "NOASSERTION" (couldn't confidently classify the license).
    func fetchGitHubLicense(repoURL: URL) async throws -> String? {
        let repo = try await fetchGitHubRepo(repoURL: repoURL)
        guard let spdx = repo.license?.spdxId,
              !spdx.isEmpty,
              spdx != "NOASSERTION" else {
            return nil
        }
        return spdx
    }

    // Normalizes a host string for comparison: lowercases and strips a leading
    // "www.".
    private func normalizedHost(_ urlString: String?) -> String {
        guard let urlString, let url = URL(string: urlString), let host = url.host else { return "" }
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    // MARK: - GitHub repo discovery (for apps with no github.com homepage)

    private func checkGitHubSearchLimit() throws {
        let now = Date()
        if now.timeIntervalSince(githubSearchWindowStart) > 60 {
            githubSearchCount = 0
            githubSearchWindowStart = now
        }
        if githubSearchCount >= githubSearchLimit {
            throw BrewAPIError.rateLimited
        }
        githubSearchCount += 1
    }

    // Best-effort: find the canonical GitHub repo for an app that does NOT have
    // a github.com homepage, by searching the GitHub repo index for the app
    // name and accepting a candidate ONLY when its declared homepage host
    // matches the cask's homepage host. That host match is the high-precision
    // signal — name/star matching alone produces wrong repos (e.g. a theme
    // "port" repo for "visual-studio-code"), so we deliberately reject those.
    // Returns nil (and caches nil) when there's no confident match.
    //
    // `token` keys the cache; `appName` is the human name to search; `homepage`
    // is the cask's homepage used for the host-match gate.
    func searchRepoURL(token: String, appName: String, homepage: String?) async -> URL? {
        if let cached = githubRepoSearchCache[token],
           Date().timeIntervalSince(cached.fetchedAt) < githubCacheTTL {
            return cached.value
        }
        // No homepage host to match against → no confident match possible.
        let caskHost = normalizedHost(homepage)
        guard !caskHost.isEmpty else {
            storeCapped(nil as URL?, forKey: token, in: &githubRepoSearchCache, cap: 300)
            return nil
        }

        // Respect the search-specific rate window; on pressure, don't cache the
        // miss (so we can try again later once the window resets).
        do {
            try checkGitHubSearchLimit()
        } catch {
            return nil
        }

        let query = "\(appName) in:name"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.github.com/search/repositories?q=\(encoded)&sort=stars&order=desc&per_page=8") else {
            storeCapped(nil as URL?, forKey: token, in: &githubRepoSearchCache, cap: 300)
            return nil
        }

        let response: GitHubSearchResponse
        do {
            response = try await fetch(url)
        } catch {
            // Network/rate error — don't cache, allow a later retry.
            return nil
        }

        // Accept the highest-starred candidate whose homepage host matches.
        var best: (url: URL, stars: Int)? = nil
        for item in response.items {
            let repoHost = normalizedHost(item.homepage)
            guard !repoHost.isEmpty else { continue }
            let hostMatch = repoHost == caskHost || repoHost.contains(caskHost) || caskHost.contains(repoHost)
            guard hostMatch else { continue }
            guard let repoURL = URL(string: "https://github.com/\(item.fullName)") else { continue }
            if best == nil || item.stargazersCount > best!.stars {
                best = (repoURL, item.stargazersCount)
            }
        }

        let result = best?.url
        storeCapped(result, forKey: token, in: &githubRepoSearchCache, cap: 300)
        return result
    }

    // MARK: - Web image search fallback (SerpApi Google Images)

    // Per-token cache of web-search screenshot URLs, so repeated detail opens
    // (within TTL) don't re-spend a SerpApi search quota unit. Caches an empty
    // array result too, to remember a confident "nothing found".
    private var screenshotSearchCache: [String: (value: [URL], fetchedAt: Date)] = [:]

    // Best-effort web image search for app screenshots, used ONLY when the
    // GitHub README path yielded nothing. Uses SerpApi's Google Images endpoint,
    // reading the key from the user's local config (~/.config/forgedbrew/config.json).
    // With no key configured this returns [] immediately and the caller falls
    // back to the GitHub social-preview image, then the "About this app" text.
    //
    // `token` keys the cache; `appName` is the human name searched. We query for
    // "<app> macOS app screenshot" and keep only reasonably large, landscape-ish
    // images (filtering out icons/logos/badges).
    func searchScreenshots(token: String, appName: String, homepage: String? = nil) async -> [URL] {
        if let cached = screenshotSearchCache[token],
           Date().timeIntervalSince(cached.fetchedAt) < githubCacheTTL {
            return cached.value
        }

        let config = ForgedBrewConfig.load()
        guard let key = config.serpApiKey else {
            // No key configured — don't cache (so it works as soon as a key is
            // added) and let the caller fall back to the next stage.
            return []
        }

        // Build a tighter query. Including the homepage domain (e.g.
        // "claude.com") biases Google toward the vendors own screenshots and
        // away from look-alike sibling products that merely share a name.
        let host = Self.primaryHost(from: homepage)
        let query = host.map { "\(appName) \($0) macOS app screenshot" }
            ?? "\(appName) macOS app screenshot"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://serpapi.com/search.json?engine=google_images&q=\(encodedQuery)&safe=active&api_key=\(encodedKey)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        // This URL carries the user's SerpApi key in its query string. Don't let
        // URLSession persist it to the on-disk URL cache (the session configures a
        // 50 MB disk cache), where the cache key would be the full key-bearing URL.
        // Results are still memoized in-process via screenshotSearchCache, so this
        // doesn't cost an extra request within the TTL.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return []   // network error — don't cache, allow retry
        }
        // Belt-and-suspenders to the .reloadIgnoringLocalCacheData policy above:
        // the request cache policy governs reads, not whether the response is
        // written, so explicitly evict any stored copy. This guarantees the
        // key-bearing URL never lingers in the on-disk URL cache.
        session.configuration.urlCache?.removeCachedResponse(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return []   // auth/quota error — don't cache
        }

        guard let decoded = try? decoder.decode(SerpImageSearchResponse.self, from: data),
              let items = decoded.imagesResults else {
            return []
        }

        let imageExts = ["png", "jpg", "jpeg", "webp"]
        // `host` was computed above for the query; reuse it for scoring.
        // Significant words from the app name, lowercased, used for relevance
        // scoring. Short filler words are dropped so e.g. "Visual Studio Code"
        // keys on "visual","studio","code".
        let nameTokens = Self.significantWords(appName)

        var seen = Set<String>()
        // Collect (url, score) so we can keep the MOST relevant results rather
        // than the first six Google happened to return. A generic image search
        // for a popular name (e.g. "Claude") pulls in look-alike siblings
        // ("Claude Code") and unrelated apps; scoring + a relevance floor keeps
        // those out while still allowing genuine matches through.
        // Each entry also records WHY it scored, so the final gate can demand
        // high confidence: a vendor-domain hit, or (for multi-word app names)
        // two or more distinct name words matched. A lone shared name word from
        // a third-party blog/forum is NOT enough — those get dropped so we fall
        // through to the always-accurate Homebrew-page thumbnail instead of
        // showing someone elses unrelated screenshot.
        var scored: [(url: URL, score: Int, onOwnDomain: Bool, nameWordHits: Int)] = []
        for item in items {
            guard let raw = item.original, let u = URL(string: raw) else { continue }

            // Skip obvious non-screenshots: icons, logos, badges.
            let lower = raw.lowercased()
            if lower.contains("icon") || lower.contains("logo") || lower.contains("badge")
                || lower.contains("favicon") || lower.contains("shields.io") { continue }

            // Prefer real raster images by extension where present. Google Images
            // results sometimes carry no extension (CDN URLs); allow those
            // through and let the cache layer validate the bytes on download.
            let ext = (u.path as NSString).pathExtension.lowercased()
            if !ext.isEmpty {
                guard imageExts.contains(ext) else { continue }
            }

            // Require a reasonable size + landscape-ish shape so we get app
            // windows, not square icons. Missing dimensions are allowed through.
            if let w = item.originalWidth, let h = item.originalHeight {
                guard w >= 400, h >= 250, Double(w) >= Double(h) * 0.9 else { continue }
            }

            guard seen.insert(raw).inserted else { continue }

            // --- Relevance scoring -------------------------------------------
            let title = (item.title ?? "").lowercased()
            let source = (item.source ?? "").lowercased()
            let sourceHost = Self.primaryHost(from: item.source) ?? source
            let haystack = "\(title) \(source) \(lower)"

            var score = 0
            // Strongest signal: the result comes from the vendors own domain.
            if let host, !host.isEmpty,
               sourceHost.contains(host) || lower.contains(host) {
                score += 5
            }
            // The apps significant words appear in the title/source.
            let matchedNameWords = nameTokens.filter { haystack.contains($0) }
            score += matchedNameWords.count * 2
            // Looks like a real screenshot rather than a marketing/hero graphic.
            if haystack.contains("screenshot") || haystack.contains("screen shot") { score += 1 }

            // Reject likely cross-product matches: the title references a
            // DIFFERENT, more-specific sibling product. Detected when the title
            // pairs one of our name words with a distinguishing extra word that
            // is NOT part of our app name (e.g. searching "Claude" but the
            // result is titled "Claude Code ..."). Same-domain hits are trusted
            // and exempt from this rejection.
            let onOwnDomain = (host.map { sourceHost.contains($0) || lower.contains($0) }) ?? false
            if !onOwnDomain, Self.looksLikeDifferentProduct(title: haystack, nameTokens: nameTokens) {
                continue
            }

            scored.append((u, score, onOwnDomain, matchedNameWords.count))
        }

        // High-confidence gate. Open-web image search reliably finds an apps
        // OWN screenshots only when results come from the vendors domain or
        // match several of the apps identifying words. For a generic
        // single-word name (e.g. "Claude") third-party blogs and forums share
        // that one word while showing entirely different things, so a lone
        // name-word match is NOT trustworthy. We therefore keep a result only
        // when it is EITHER on the vendors own domain OR matches 2+ distinct
        // name words. If nothing clears the bar we return [] so the caller
        // falls through to the always-accurate Homebrew-page thumbnail rather
        // than displaying an unrelated screenshot.
        let confident = scored.filter { $0.onOwnDomain || $0.nameWordHits >= 2 }
        let results = confident
            .sorted { $0.score > $1.score }
            .prefix(6)
            .map(\.url)

        let final = Array(results)
        storeCapped(final, forKey: token, in: &screenshotSearchCache, cap: 200)
        return final
    }

    // The registrable-ish host of a URL string, lowercased, with a leading
    // "www." stripped (e.g. "https://www.claude.com/download" -> "claude.com").
    // Returns nil when no host can be parsed.
    nonisolated static func primaryHost(from urlString: String?) -> String? {
        guard let s = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        // Allow bare hosts ("claude.com") as well as full URLs.
        let candidate = s.contains("://") ? s : "https://\(s)"
        guard let host = URL(string: candidate)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // Significant, lowercased words of an app name for relevance scoring. Drops
    // very short tokens and common filler so matching keys on the words that
    // actually identify the app.
    nonisolated static func significantWords(_ name: String) -> [String] {
        let filler: Set<String> = ["the", "for", "and", "app", "macos", "mac", "os", "x"]
        return name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !filler.contains($0) }
    }

    // Heuristic: does this result title look like a DIFFERENT product that
    // merely shares a name word with ours? True when the title contains one of
    // our name words immediately followed by a distinguishing extra word that
    // is not part of our app name (e.g. our app is "Claude" but the title says
    // "Claude Code" / "Claude Desktop Pro"). Used only for off-domain results.
    nonisolated static func looksLikeDifferentProduct(title: String, nameTokens: [String]) -> Bool {
        guard !nameTokens.isEmpty else { return false }
        let words = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let nameSet = Set(nameTokens)
        // Words that, when appended to a name word, signal a distinct sibling
        // product line rather than a descriptor of the same app.
        let productSuffixes: Set<String> = ["code", "cli", "pro", "lite", "max", "plus",
                                            "enterprise", "studio", "server", "desktop",
                                            "mobile", "web", "cloud", "beta", "nightly"]
        for i in 0..<words.count {
            guard nameSet.contains(words[i]) else { continue }
            if i + 1 < words.count {
                let next = words[i + 1]
                if productSuffixes.contains(next), !nameSet.contains(next) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - GitHub README

    // Fetches and base64-decodes the repo's default README (the primary "About
    // this app" source for open-source packages). GitHub returns the README
    // body base64-encoded in a JSON envelope; we strip the line breaks it
    // inserts before decoding. Result is TTL-cached (capped) per repo.
    func fetchGitHubReadme(repoURL: URL) async throws -> String {
        guard let (owner, repo) = extractOwnerRepo(from: repoURL) else {
            throw BrewAPIError.invalidURL
        }
        let key = cacheKey(owner: owner, repo: repo)
        if let cached = githubReadmeCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < githubCacheTTL {
            return cached.value
        }
        try checkGitHubRateLimit()
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/readme") else {
            throw BrewAPIError.invalidURL
        }
        let payload: GitHubReadme = try await fetch(url)
        let cleaned = payload.content
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let data = Data(base64Encoded: cleaned),
              let text = String(data: data, encoding: .utf8) else {
            throw BrewAPIError.decodingError(
                NSError(domain: "BrewAPI", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode README base64"])
            )
        }
        storeCapped(text, forKey: key, in: &githubReadmeCache, cap: 200)
        return text
    }

    // MARK: - About blurb (Wikipedia) — fallback for closed-source apps

    // Decodes the parts of Wikipedia's REST summary response we use.
    private struct WikipediaSummary: Decodable {
        let extract: String?
        let type: String?
        let title: String?
        // Wikipedia's one-line short descriptor (e.g. "2025 WWE event" or
        // "open-source software"). A strong relevance signal both ways.
        let description: String?
    }

    // Best-effort short descriptive paragraph for an app that has NO GitHub
    // repo (so no README). Used only as the About tab's last-resort content for
    // closed-source apps (iTerm2, Raycast, Cursor, 1Password, …). Queries
    // Wikipedia's free REST summary endpoint (no API key, no GitHub rate limit)
    // for the app name and returns its lead extract. Returns nil when there's no
    // confident article (missing, disambiguation, or empty) — the caller then
    // shows the Homebrew metadata panel alone. Cached (including nil misses) for
    // the session so reopening the tab is instant.
    func fetchAboutBlurb(appName: String, aliases: [String] = [], homepage: String? = nil) async -> String? {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed.lowercased()
        if let cached = aboutBlurbCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < githubCacheTTL {
            return cached.value
        }

        // Build an ordered, de-duplicated list of candidate titles to try:
        // the display name first, then any caller-supplied aliases (e.g.
        // "Cloudflare Tunnel", "Argo Tunnel" for the cloudflared formula).
        var candidates: [String] = []
        for c in ([trimmed] + aliases) {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !candidates.contains(where: { $0.lowercased() == t.lowercased() }) {
                candidates.append(t)
            }
        }

        // 1) Try each candidate as a direct REST summary title. Only accept a
        //    summary that actually looks like it's about THIS software — a
        //    name like "Clash Party" can otherwise match an unrelated famous
        //    topic (e.g. a WWE wrestling event). See isRelevantWikiSummary.
        for cand in candidates {
            if let summary = await wikipediaSummary(title: cand),
               isRelevantWikiSummary(summary, appName: trimmed, homepage: homepage),
               let extract = summaryExtractText(summary) {
                storeCapped(extract, forKey: key, in: &aboutBlurbCache, cap: 300)
                return extract
            }
        }

        // 2) Nothing matched by exact title — use Wikipedia's opensearch to
        //    resolve the best-matching article title for the primary name,
        //    then pull that article's summary. This rescues names that don't
        //    map 1:1 to an article (e.g. "cloudflared" -> "Cloudflare"). The
        //    same relevance gate applies, because opensearch is exactly where
        //    ambiguous names drift onto the wrong popular article.
        if let resolved = await wikipediaOpenSearchTitle(query: trimmed),
           let summary = await wikipediaSummary(title: resolved),
           isRelevantWikiSummary(summary, appName: trimmed, homepage: homepage),
           let extract = summaryExtractText(summary) {
            storeCapped(extract, forKey: key, in: &aboutBlurbCache, cap: 300)
            return extract
        }

        // 3) Disambiguated retry (Loom problem). A bare common-word/proper-name
        //    query like "Loom" resolves to the wrong entity (the weaving tool),
        //    which the relevance gate rejects, leaving us with nothing. Retry
        //    opensearch with software qualifiers so we land on the APP article
        //    ("Loom (software)" / "Loom app"). The relevance gate still runs, so
        //    a wrong hit is still rejected — this only RESCUES the cases that
        //    would otherwise return nil, it can never let a bad match through.
        for qualifier in ["\(trimmed) (software)", "\(trimmed) app", "\(trimmed) (application)"] {
            if let resolved = await wikipediaOpenSearchTitle(query: qualifier),
               let summary = await wikipediaSummary(title: resolved),
               isRelevantWikiSummary(summary, appName: trimmed, homepage: homepage),
               let extract = summaryExtractText(summary) {
                storeCapped(extract, forKey: key, in: &aboutBlurbCache, cap: 300)
                return extract
            }
        }

        storeCapped(nil, forKey: key, in: &aboutBlurbCache, cap: 300)
        return nil
    }

    // Heuristic relevance gate: decide whether a Wikipedia summary is plausibly
    // ABOUT the given software package, rather than an unrelated topic that
    // merely shares the name. Returns true on either strong signal:
    //   • Homepage-domain confirmation — the article text or short description
    //     mentions the package's homepage second-level domain (e.g. the article
    //     about a real app usually names its own site / project), OR
    //   • Software-relevance — the extract or short description contains
    //     software/technology signal words (software, app, open-source, GUI,
    //     command-line, macOS, Linux, client, library, framework, tool, …).
    // Anything else is rejected so we fall back to README / homepage / desc.
    private func isRelevantWikiSummary(_ summary: WikipediaSummary, appName: String, homepage: String?) -> Bool {
        let extract = (summary.extract ?? "").lowercased()
        let shortDesc = (summary.description ?? "").lowercased()
        let hay = extract + " " + shortDesc
        guard !hay.trimmingCharacters(in: .whitespaces).isEmpty else { return false }

        // Strong negative: Wikipedia short descriptions for clearly non-software
        // topics (events, films, albums, people, songs, sportspeople, animals,
        // plants, etc.). A name like "simdjson" can fuzzy-match "The Simpsons";
        // these short-description tokens reject the obvious non-software hits.
        let negativeDescTokens = [
            "wrestling", "pay-per-view", "ppv", "film", "movie", "album",
            "song", "single ", "television series", "tv series", "sitcom",
            "footballer", "musician", "band", "actor", "actress", "politician",
            "novel", "video game character", "sporting event", "championship",
            "tournament", "athlete", "singer", "rapper", "wwe", "ufc", "boxer",
            // Nature / biology — bison, mongoose, etc. share names with tools.
            "genus", "species", "mammal", "animal", "bird", "fish", "plant",
            "bovine", "insect", "reptile", "dinosaur", "breed of",
            // People / places / misc non-software topics.
            "village", "town", "city in", "river", "mountain", "deity",
            "mythology", "given name", "surname", "comic", "manga", "anime",
            // Non-software things that famously collide with app names:
            // Vivaldi (composer), Obsidian (volcanic glass), Opera (theatre art
            // form), Loom (weaving device), Fork (eating utensil), Signal, etc.
            "composer", "violinist", "baroque", "classical music",
            "volcanic glass", "igneous", "mineral", "rock formation", "gemstone",
            "art form", "theatre", "theater", "opera house", "ballet",
            "weaving", "weave", "loom", "textile", "tapestry", "yarn",
            "utensil", "cutlery", "tableware", "kitchenware", "eating implement",
            "anatomy", "anatomical", "body part", "muscle", "bone",
            "chemical compound", "chemical element", "molecule",
            "card game", "board game", "dance", "cocktail", "dish ",
            "religious", "saint", "monarch", "emperor", "king of", "queen of",
            "constellation", "star system", "asteroid", "comet", "moon of"
        ]
        if negativeDescTokens.contains(where: { shortDesc.contains($0) }) {
            return false
        }

        // Title-overlap guard runs FIRST. Reject when the resolved article
        // title shares no meaningful token with the package name. This kills
        // fuzzy opensearch drift such as "simdjson" -> "The Simpsons" AND the
        // incidental-mention trap (the "SureStop" article mentions an old name
        // "SlidePad" in its body, which previously matched the slidepad.app
        // homepage domain and short-circuited acceptance before any title
        // check). No incidental body wording can let a wrong title through now.
        if !titlesPlausiblyMatch(appName: appName, articleTitle: summary.title) {
            return false
        }

        // Strong accept #1: homepage second-level domain appears in the article.
        // The article names the project's own site — a high-confidence signal.
        // Now gated behind the title guard above, so it can only confirm an
        // already-plausible article, never rescue an unrelated one.
        if let domainCore = homepageDomainCore(homepage), domainCore.count >= 3,
           hay.contains(domainCore) {
            return true
        }

        // Strong accept #2: software / technology signal words. Each token is
        // matched on a WORD boundary (not a raw substring) so short tokens like
        // "ide", "cli", "api", "app" can't false-positive inside ordinary words
        // ("identity", "considered", "Springfield", …) — the exact bug that let
        // "The Simpsons" pass via the "ide" inside "identity".
        let softwareTokens = [
            "software", "application", "applications", "app", "apps",
            "open-source", "open source", "freeware", "gui",
            "command-line", "cli", "macos", "linux", "windows",
            "cross-platform", "client", "server", "library", "libraries",
            "framework", "frameworks", "toolkit", "tool", "tools", "utility",
            "plugin", "extension", "programming", "developer", "compiler",
            "parser", "api", "sdk", "runtime", "daemon", "kernel",
            "operating system", "browser", "editor", "ide", "terminal"
        ]
        if softwareTokens.contains(where: { wordPresent($0, in: hay) }) {
            return true
        }

        return false
    }

    // True when `token` appears in `hay` bounded by non-alphanumeric characters
    // (or string edges). Multi-word tokens (containing a space or hyphen) are
    // matched verbatim as a substring since their own boundaries are explicit.
    private func wordPresent(_ token: String, in hay: String) -> Bool {
        if token.contains(" ") || token.contains("-") {
            return hay.contains(token)
        }
        var searchStart = hay.startIndex
        while let range = hay.range(of: token, range: searchStart..<hay.endIndex) {
            let beforeOK: Bool = {
                guard range.lowerBound > hay.startIndex else { return true }
                let prev = hay[hay.index(before: range.lowerBound)]
                return !prev.isLetter && !prev.isNumber
            }()
            let afterOK: Bool = {
                guard range.upperBound < hay.endIndex else { return true }
                let next = hay[range.upperBound]
                return !next.isLetter && !next.isNumber
            }()
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    // Decides whether a Wikipedia article title is plausibly about the package.
    // Accepts when the package name appears (case-insensitively) inside the
    // title, OR the two share a significant alphabetic token (length >= 4) so
    // common short words don't create accidental matches. A nil/empty title is
    // treated as a non-match.
    private func titlesPlausiblyMatch(appName: String, articleTitle: String?) -> Bool {
        guard let raw = articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        let title = raw.lowercased()
        let name = appName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        // Direct containment either way (handles "cloudflared" -> "Cloudflare"
        // and "VLC media player" -> "VLC").
        if title.contains(name) || name.contains(title) { return true }
        func tokens(_ s: String) -> Set<String> {
            let cleaned = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            return Set(String(cleaned).split(separator: " ").map(String.init).filter { $0.count >= 4 })
        }
        let nameTokens = tokens(name)
        guard !nameTokens.isEmpty else {
            // Very short names (e.g. "go", "jq") have no >=4 token to compare;
            // require direct containment, already handled above -> reject here.
            return false
        }
        return !nameTokens.isDisjoint(with: tokens(title))
    }

    // Returns the lowercased second-level domain label of a homepage URL, e.g.
    // "https://clashparty.org/" -> "clashparty", "https://www.gnu.org" -> "gnu".
    // Used to confirm a Wikipedia article is about the right project.
    private func homepageDomainCore(_ homepage: String?) -> String? {
        guard let homepage,
              let host = URLComponents(string: homepage)?.host?.lowercased() else { return nil }
        var parts = host.split(separator: ".").map(String.init)
        // Drop a leading "www".
        if parts.first == "www" { parts.removeFirst() }
        // Second-level label is the one before the public suffix.
        guard parts.count >= 2 else { return parts.first }
        return parts[parts.count - 2]
    }

    // Returns the cleaned lead extract of a summary, or nil for a missing /
    // disambiguation / empty article (mirrors the old wikipediaSummaryExtract).
    private func summaryExtractText(_ summary: WikipediaSummary) -> String? {
        let extract = (summary.extract ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.type == "disambiguation" || extract.isEmpty { return nil }
        return extract
    }

    // Fetches one Wikipedia REST summary by title and returns the full decoded
    // struct (extract + type + short description), or nil on failure. Callers
    // can then apply their own relevance gate before trusting the extract.
    private func wikipediaSummary(title: String) async -> WikipediaSummary? {
        let titleSlug = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        guard !titleSlug.isEmpty,
              let encoded = titleSlug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)?redirect=true") else {
            return nil
        }
        do { return try await fetch(url) } catch { return nil }
    }

    // Fetches one Wikipedia REST summary by title and returns its lead extract,
    // or nil for a missing / disambiguation / empty article.
    private func wikipediaSummaryExtract(title: String) async -> String? {
        guard let summary = await wikipediaSummary(title: title) else { return nil }
        return summaryExtractText(summary)
    }

    // Uses Wikipedia's opensearch API to resolve a free-text query to the best
    // matching article title. Returns nil if nothing matches. No API key.
    private func wikipediaOpenSearchTitle(query: String) async -> String? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&limit=1&namespace=0&format=json&search=\(q)") else {
            return nil
        }
        // opensearch returns a heterogeneous JSON array: [query, [titles], [descs], [urls]].
        var request = URLRequest(url: url)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let titles = json[1] as? [String],
              let first = titles.first,
              !first.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return first
    }

    // ------------------------------------------------------------------
    // Homepage HTML metadata
    // ------------------------------------------------------------------

    // The slice of a homepage's HTML <head> we can use to enrich a detail card:
    // a human title, a description paragraph (meta description / og:description),
    // and a representative image (og:image) we can show as a screenshot fallback.
    struct HomepageMeta: Sendable {
        var title: String?
        var description: String?
        var imageURL: URL?
    }

    // Fetches a homepage's HTML and extracts <title>, meta description /
    // og:description, and og:image. Used to enrich the Overview / More Info
    // tabs and to provide a screenshot candidate for apps with a rich homepage
    // but no real screenshots (e.g. cloudflared). Cached (including nil misses)
    // for the session so reopening a card is instant and cheap. One lightweight
    // GET per homepage.
    func fetchHomepageMeta(homepage: String?) async -> HomepageMeta? {
        guard let homepage = homepage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !homepage.isEmpty,
              let url = URL(string: homepage),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        let key = homepage.lowercased()
        if let cached = homepageMetaCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < githubCacheTTL {
            return cached.value
        }
        guard let html = await fetchString(url) else {
            storeCapped(nil as HomepageMeta?, forKey: key, in: &homepageMetaCache, cap: 300)
            return nil
        }
        let meta = Self.parseHomepageMeta(html: html, baseURL: url)
        // Treat a result with no usable text or image as a miss.
        let usable = (meta.description?.isEmpty == false) || (meta.title?.isEmpty == false) || (meta.imageURL != nil)
        let value: HomepageMeta? = usable ? meta : nil
        storeCapped(value, forKey: key, in: &homepageMetaCache, cap: 300)
        return value
    }

    // Parses the bits we need out of a homepage's HTML using lightweight regex
    // (we don't need a full HTML parser for a <head> meta scrape). og:* tags
    // win over the plain <title>/<meta name="description"> when present.
    nonisolated static func parseHomepageMeta(html: String, baseURL: URL) -> HomepageMeta {
        func firstMatch(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
            let range = NSRange(html.startIndex..., in: html)
            guard let m = re.firstMatch(in: html, options: [], range: range), m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: html) else { return nil }
            return String(html[r])
        }
        func decode(_ s: String?) -> String? {
            guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#x27;": "'"]
            for (e, c) in entities { t = t.replacingOccurrences(of: e, with: c) }
            // Collapse runs of whitespace/newlines into single spaces.
            t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let ogTitle = firstMatch("<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']*)[\"']")
            ?? firstMatch("<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+property=[\"']og:title[\"']")
        let docTitle = firstMatch("<title[^>]*>(.*?)</title>")
        let metaDesc = firstMatch("<meta[^>]+name=[\"']description[\"'][^>]+content=[\"']([^\"']*)[\"']")
            ?? firstMatch("<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+name=[\"']description[\"']")
        let ogDesc = firstMatch("<meta[^>]+property=[\"']og:description[\"'][^>]+content=[\"']([^\"']*)[\"']")
            ?? firstMatch("<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+property=[\"']og:description[\"']")
        let ogImage = firstMatch("<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']*)[\"']")
            ?? firstMatch("<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+property=[\"']og:image[\"']")

        var meta = HomepageMeta()
        meta.title = decode(ogTitle) ?? decode(docTitle)
        meta.description = decode(ogDesc) ?? decode(metaDesc)
        if let img = decode(ogImage), let u = URL(string: img, relativeTo: baseURL)?.absoluteURL {
            meta.imageURL = u
        }
        return meta
    }

    // ------------------------------------------------------------------
    // GitHub wiki fallback
    // ------------------------------------------------------------------

    // Best-effort blurb pulled from a project's GitHub wiki Home page, used as a
    // secondary "project wiki" source when Wikipedia has no confident article.
    // Fetches the raw wiki Home markdown (github.com/<owner>/<repo>/wiki/Home.md
    // via the wiki repo's raw endpoint is unreliable; instead we read the
    // rendered wiki Home page HTML and lift its first paragraphs). Returns the
    // lead text, or nil when there's no wiki. Cached (including nil) per repo.
    func fetchGitHubWikiBlurb(repoURL: URL) async -> String? {
        // Expect a github.com/<owner>/<repo> URL.
        let parts = repoURL.path.split(separator: "/").map(String.init)
        guard repoURL.host?.contains("github.com") == true, parts.count >= 2 else { return nil }
        let owner = parts[0], repo = parts[1].replacingOccurrences(of: ".git", with: "")
        let key = "\(owner)/\(repo)".lowercased()
        if let cached = githubWikiCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < githubCacheTTL {
            return cached.value
        }
        guard let url = URL(string: "https://github.com/\(owner)/\(repo)/wiki") else {
            storeCapped(nil as String?, forKey: key, in: &githubWikiCache, cap: 200); return nil
        }
        guard let html = await fetchString(url) else {
            storeCapped(nil as String?, forKey: key, in: &githubWikiCache, cap: 200); return nil
        }
        // Lift the rendered wiki body's text. The wiki content lives in a
        // .markdown-body container; grab its first text paragraphs.
        let blurb = Self.firstParagraphsFromMarkdownBody(html: html)
        let value = (blurb?.isEmpty == false) ? blurb : nil
        storeCapped(value, forKey: key, in: &githubWikiCache, cap: 200)
        return value
    }

    // Pulls the first couple of readable paragraphs out of a GitHub-rendered
    // .markdown-body HTML block, stripping tags. Returns nil if not found.
    nonisolated static func firstParagraphsFromMarkdownBody(html: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: "<div[^>]+class=[\"'][^\"']*markdown-body[^\"']*[\"'][^>]*>(.*?)</div>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let m = re.firstMatch(in: html, options: [], range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: html) else { return nil }
        var body = String(html[r])
        // Keep paragraph breaks, drop all other tags.
        body = body.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (e, c) in entities { body = body.replacingOccurrences(of: e, with: c) }
        let paras = body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paras.isEmpty else { return nil }
        // Take up to the first 2 paragraphs, capped for a tidy blurb.
        let joined = paras.prefix(2).joined(separator: "\n\n")
        return String(joined.prefix(800))
    }

    // Raw text/HTML GET (the generic fetch<T> only decodes JSON). Returns the
    // decoded string body, or nil on any network / non-2xx error.
    private func fetchString(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // ------------------------------------------------------------------
    // Full Wikipedia article (More Info long-form)
    // ------------------------------------------------------------------

    // Fetches the FULL plain-text body of a Wikipedia article (not just the
    // short summary the Overview uses) and returns it formatted as light
    // Markdown: section titles become "## Heading" so the More Info renderer
    // styles them. Resolves the title via opensearch when the raw name doesn't
    // map to an article (e.g. "cloudflared" -> "Cloudflare"). Returns nil when
    // there's no confident article. Cached (including nil) per query.
    func fetchWikipediaFullArticle(appName: String, aliases: [String] = [], homepage: String? = nil) async -> String? {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed.lowercased()
        if let cached = wikiFullArticleCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < githubCacheTTL {
            return cached.value
        }

        // Build candidate titles (name + aliases), then opensearch as a rescue.
        var candidates: [String] = []
        for c in ([trimmed] + aliases) {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !candidates.contains(where: { $0.lowercased() == t.lowercased() }) {
                candidates.append(t)
            }
        }
        // Gate each candidate the same way the Overview blurb does: confirm via
        // the REST summary that the article is plausibly about THIS software
        // before pulling its whole body. This stops a name like "Clash Party"
        // from rendering a full unrelated article (e.g. a WWE event).
        for cand in candidates {
            guard let summary = await wikipediaSummary(title: cand),
                  isRelevantWikiSummary(summary, appName: trimmed, homepage: homepage) else { continue }
            if let body = await wikipediaExtractMarkdown(title: cand) {
                storeCapped(body, forKey: key, in: &wikiFullArticleCache, cap: 150)
                return body
            }
        }
        if let resolved = await wikipediaOpenSearchTitle(query: trimmed),
           let summary = await wikipediaSummary(title: resolved),
           isRelevantWikiSummary(summary, appName: trimmed, homepage: homepage),
           let body = await wikipediaExtractMarkdown(title: resolved) {
            storeCapped(body, forKey: key, in: &wikiFullArticleCache, cap: 150)
            return body
        }
        // Disambiguated retry (Loom problem) — mirror fetchAboutBlurb: when the
        // bare name resolves to the wrong entity (and is rejected by the gate),
        // retry with software qualifiers so the full article lands on the APP.
        // The relevance gate still runs, so a wrong match is still rejected.
        for qualifier in ["\(trimmed) (software)", "\(trimmed) app", "\(trimmed) (application)"] {
            if let resolved = await wikipediaOpenSearchTitle(query: qualifier),
               let summary = await wikipediaSummary(title: resolved),
               isRelevantWikiSummary(summary, appName: trimmed, homepage: homepage),
               let body = await wikipediaExtractMarkdown(title: resolved) {
                storeCapped(body, forKey: key, in: &wikiFullArticleCache, cap: 150)
                return body
            }
        }
        storeCapped(nil, forKey: key, in: &wikiFullArticleCache, cap: 150)
        return nil
    }

    // Decodes the MediaWiki "extracts" response (plain text, with section
    // headings marked) and converts it to light Markdown.
    private struct WikiExtractQuery: Decodable {
        struct Query: Decodable {
            struct Page: Decodable {
                let extract: String?
                let missing: String?
                let title: String?
            }
            let pages: [String: Page]?
        }
        let query: Query?
    }

    // Fetches one article's full extract via action=query&prop=extracts in
    // plaintext mode (explaintext) and reformats its "Section ==="-style
    // headings into Markdown. Returns nil for a missing / empty article.
    private func wikipediaExtractMarkdown(title: String) async -> String? {
        guard let t = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&redirects=1&format=json&titles=\(t)") else {
            return nil
        }
        let resp: WikiExtractQuery
        do { resp = try await fetch(url) } catch { return nil }
        guard let pages = resp.query?.pages, let page = pages.values.first,
              page.missing == nil,
              let raw = page.extract?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return Self.wikiPlainTextToMarkdown(raw, title: page.title ?? title)
    }

    // The plaintext extract uses MediaWiki section markers like:
    //   "\n\n== History ==\n..." (h2), "\n\n=== Sub ===\n..." (h3).
    // Convert those to Markdown headings so the renderer styles them, drop the
    // trailing reference/see-also sections, and cap the length for a tidy page.
    nonisolated static func wikiPlainTextToMarkdown(_ text: String, title: String) -> String {
        var out: [String] = []
        // Lead with the article title as an h1 so the page reads as a document.
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty { out.append("# \(cleanTitle)") }
        // Sections we don't want in an in-app reader.
        let dropHeadings: Set<String> = ["references", "external links", "see also",
                                         "further reading", "notes", "citations",
                                         "bibliography", "sources"]
        var skipping = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if !skipping { out.append("") }; continue }
            // Heading line? "=== X ===" / "== X ==".
            if line.hasPrefix("==") && line.hasSuffix("==") {
                let level = line.prefix(while: { $0 == "=" }).count
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
                if dropHeadings.contains(name.lowercased()) { skipping = true; continue }
                skipping = false
                // == -> ## (h2), === -> ### (h3), deeper clamps to ###.
                let hashes = String(repeating: "#", count: min(max(level, 2), 3))
                out.append("")
                out.append("\(hashes) \(name)")
                continue
            }
            if skipping { continue }
            out.append(line)
        }
        var md = out.joined(separator: "\n")
        // Collapse 3+ blank lines and trim.
        md = md.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Cap to keep the reader snappy (a few thousand chars is a full page).
        if md.count > 8000 { md = String(md.prefix(8000)) + "\n\n…" }
        return md
    }
}
