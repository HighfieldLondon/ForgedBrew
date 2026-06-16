import Foundation

// MARK: - CaskCatalog
//
// A read-only snapshot of Homebrew's cask catalog, used as the "catch-all"
// source for the App Updates screen AND to decide which non-Homebrew apps can
// be Adopted into Homebrew from the Mac App / Other Apps rows.
//
// Why this exists:
//   ForgedBrew's App Updates scanner originally detected updates only from Sparkle
//   (SUFeedURL), GitHub (homepage/feed → repo), and the Mac App Store
//   (_MASReceipt). A large class of popular apps — Visual Studio Code, for one —
//   use none of those: they ship a *proprietary* updater and carry no Sparkle
//   feed, no GitHub link, and no App Store receipt. Those apps were silently
//   missed even though a newer version plainly exists.
//
//   Homebrew already knows the latest version of nearly every such app, because
//   it ships a *cask* for it. ForgedBrew already loads the full cask catalog as
//   [CaskMetadata] (token + names + version + homepage); we build this lookup
//   from THAT in-memory catalog (see `from(casks:)`), so it stays correct
//   regardless of how Homebrew lays out its on-disk cache. A file-reading
//   fallback (`load()`) remains for callers that have no catalog handy.
//
// Matching against an installed app is done by the app's .app *file name*
// (e.g. "Visual Studio Code.app") first, then by a normalized name key so apps
// whose cask ships a *pkg* installer instead of an `.app` artifact (e.g.
// OneDrive) still match by name. The version comparison in the probe is the
// real guard against false positives — we only surface an app when the cask
// version is strictly newer than what's installed on disk.
nonisolated struct CaskCatalog: Sendable {

    // One catalog entry: the minimum we need to surface an update + route the
    // user somewhere useful.
    struct Entry: Sendable {
        let token: String        // cask token, e.g. "visual-studio-code"
        let version: String      // latest version Homebrew knows, e.g. "1.123.0"
        let homepage: String?    // app homepage, used as the "check manually" link
    }

    // app-file-name (lowercased, e.g. "visual studio code.app") → entry.
    // This is the primary, most reliable key: it matches the literal bundle the
    // cask installs against the bundle the user actually has.
    private let byAppName: [String: Entry]
    // human cask name (lowercased) → entry, as a secondary fallback when the
    // installed bundle's display name differs from its file name.
    private let byDisplayName: [String: Entry]
    // normalized key (letters+digits only, lowercased) → entry. Lets an app
    // name like "OneDrive" match the cask token "onedrive" or name "OneDrive"
    // even when the cask has no `.app` artifact to key off (pkg-based casks).
    private let byNormalizedName: [String: Entry]

    // Normalize a label (app name or cask token/name) for fuzzy-but-safe
    // matching: lowercase, keep only letters and digits. "Google Chrome",
    // "google-chrome", and "GoogleChrome" all collapse to "googlechrome".
    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.lowercased().unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    // Look up a cask for an installed app. Tries the .app file name, then the
    // app's display name, then a normalized-name match (covers pkg-based casks
    // such as OneDrive that ship no `.app` artifact). `appFileName` should
    // include ".app".
    func entry(appFileName: String, displayName: String?) -> Entry? {
        let fileKey = appFileName.lowercased()
        if let hit = byAppName[fileKey] { return hit }
        // Try mapping a bare name to "<name>.app" too, in case the caller
        // passed a name without the extension.
        if !fileKey.hasSuffix(".app"), let hit = byAppName[fileKey + ".app"] { return hit }
        if let displayName, let hit = byDisplayName[displayName.lowercased()] { return hit }

        // Normalized-name fallback: strip ".app", then match on the
        // letters+digits-only key against both cask names and tokens.
        let bareName = fileKey.hasSuffix(".app") ? String(fileKey.dropLast(4)) : fileKey
        let normKey = Self.normalize(bareName)
        if !normKey.isEmpty, let hit = byNormalizedName[normKey] { return hit }
        if let displayName {
            let dispKey = Self.normalize(displayName)
            if !dispKey.isEmpty, let hit = byNormalizedName[dispKey] { return hit }
        }
        return nil
    }

    var isEmpty: Bool { byAppName.isEmpty && byDisplayName.isEmpty && byNormalizedName.isEmpty }

    // MARK: - Build from the in-memory catalog (primary path)

    // Build the lookup from ForgedBrew's already-loaded cask catalog. This is
    // the preferred constructor: it never depends on Homebrew's on-disk cache
    // layout (which changes between brew versions). Unversioned ("latest")
    // and deprecated casks are skipped.
    static func from(casks: [CaskMetadata]) -> CaskCatalog {
        var byApp: [String: Entry] = [:]
        var byName: [String: Entry] = [:]
        var byNorm: [String: Entry] = [:]
        byNorm.reserveCapacity(casks.count)

        for cask in casks where !cask.deprecated {
            guard let version = cask.version,
                  !version.isEmpty, version != "latest" else { continue }
            let entry = Entry(token: cask.token, version: version, homepage: cask.homepage)

            // Token, normalized (e.g. "onedrive"). First-write wins so a
            // token's own spelling isn't clobbered by another cask's name.
            let tokenKey = normalize(cask.token)
            if !tokenKey.isEmpty, byNorm[tokenKey] == nil { byNorm[tokenKey] = entry }

            // Every human name: as a display-name key AND a normalized key, and
            // as a best-effort "<name>.app" filename key (covers the common
            // case where the bundle file name equals the cask's display name).
            for name in cask.name {
                let lower = name.lowercased()
                if byName[lower] == nil { byName[lower] = entry }
                if byApp[lower + ".app"] == nil { byApp[lower + ".app"] = entry }
                let nkey = normalize(name)
                if !nkey.isEmpty, byNorm[nkey] == nil { byNorm[nkey] = entry }
            }
        }
        return CaskCatalog(byAppName: byApp, byDisplayName: byName, byNormalizedName: byNorm)
    }

    // MARK: - Loading from Homebrew's on-disk cache (fallback)

    // Build the catalog from Homebrew's cached cask JSON. Returns an empty
    // catalog (never nil) on any failure, so the caller can treat "no catalog"
    // and "empty catalog" identically and simply skip the cask source. Prefer
    // `from(casks:)` when the in-memory catalog is available.
    static func load() -> CaskCatalog {
        guard let url = cacheFileURL(),
              let data = try? Data(contentsOf: url) else {
            return CaskCatalog(byAppName: [:], byDisplayName: [:], byNormalizedName: [:])
        }
        return parse(jwsData: data)
    }

    // Homebrew's local catalog cache. Honors HOMEBREW_CACHE; otherwise defaults
    // to ~/Library/Caches/Homebrew. Handles both the modern 6.x layout
    // (api/internal/packages.<arch>.jws.json) and the legacy api/cask.jws.json.
    private static func cacheFileURL() -> URL? {
        let fm = FileManager.default
        var roots: [String] = []
        if let envCache = ProcessInfo.processInfo.environment["HOMEBREW_CACHE"] {
            roots.append(envCache)
        }
        let home = fm.homeDirectoryForCurrentUser.path
        roots.append((home as NSString).appendingPathComponent("Library/Caches/Homebrew"))

        for root in roots {
            let apiDir = (root as NSString).appendingPathComponent("api")
            // Homebrew 6.x: a single signed bundle holding formulae AND casks at
            // api/internal/packages.<arch>.jws.json. The arch/codename suffix
            // varies per machine, so glob for it instead of hard-coding.
            let internalDir = (apiDir as NSString).appendingPathComponent("internal")
            if let entries = try? fm.contentsOfDirectory(atPath: internalDir) {
                let pick = entries
                    .filter { $0.hasPrefix("packages.") && $0.hasSuffix(".jws.json") }
                    .sorted()
                    .first
                if let pick {
                    return URL(fileURLWithPath: (internalDir as NSString).appendingPathComponent(pick))
                }
            }
            // Legacy (Homebrew ≤ 4.x): a cask-only catalog at api/cask.jws.json.
            let legacy = (apiDir as NSString).appendingPathComponent("cask.jws.json")
            if fm.fileExists(atPath: legacy) {
                return URL(fileURLWithPath: legacy)
            }
        }
        return nil
    }

    // The cache is a JWS envelope: { "payload": "<json-string>", … }. We don't
    // verify the signature (Homebrew did when it wrote the file) and we only
    // read version strings — never execute anything from it.
    static func parse(jwsData: Data) -> CaskCatalog {
        guard
            let envelope = try? JSONSerialization.jsonObject(with: jwsData) as? [String: Any],
            let payloadString = envelope["payload"] as? String,
            let payloadData = payloadString.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: payloadData)
        else {
            return CaskCatalog(byAppName: [:], byDisplayName: [:], byNormalizedName: [:])
        }

        var byApp: [String: Entry] = [:]
        var byName: [String: Entry] = [:]
        var byNorm: [String: Entry] = [:]

        // Homebrew 6.x packages.<arch>.jws.json: payload is an object whose
        // "casks" is a DICTIONARY keyed by token; each value carries "version",
        // "names", "homepage", and "raw_artifacts" ([ [stanza, value], … ]).
        if let obj = payload as? [String: Any],
           let casks = obj["casks"] as? [String: [String: Any]] {
            byNorm.reserveCapacity(casks.count)
            for (token, cask) in casks {
                guard let version = cask["version"] as? String,
                      !version.isEmpty, version != "latest" else { continue }
                let entry = Entry(token: token, version: version,
                                  homepage: cask["homepage"] as? String)
                let tokenKey = normalize(token)
                if !tokenKey.isEmpty, byNorm[tokenKey] == nil { byNorm[tokenKey] = entry }
                indexAppNames(rawArtifacts: cask["raw_artifacts"], entry: entry, into: &byApp)
                indexHumanNames(cask["names"], entry: entry, byName: &byName, byNorm: &byNorm)
            }
            return CaskCatalog(byAppName: byApp, byDisplayName: byName, byNormalizedName: byNorm)
        }

        // Legacy (Homebrew ≤ 4.x) cask.jws.json: payload is an ARRAY of casks,
        // each with inline "token", "artifacts" ([{"app": [...]}]), and "name".
        if let casks = payload as? [[String: Any]] {
            byNorm.reserveCapacity(casks.count)
            for cask in casks {
                guard
                    let token = cask["token"] as? String,
                    let version = cask["version"] as? String,
                    !version.isEmpty, version != "latest"
                else { continue }
                let entry = Entry(token: token, version: version,
                                  homepage: cask["homepage"] as? String)
                let tokenKey = normalize(token)
                if !tokenKey.isEmpty, byNorm[tokenKey] == nil { byNorm[tokenKey] = entry }
                if let artifacts = cask["artifacts"] as? [[String: Any]] {
                    for artifact in artifacts {
                        guard let apps = artifact["app"] as? [Any] else { continue }
                        for case let appName as String in apps {
                            register(appFileName: appName, entry: entry, into: &byApp)
                        }
                    }
                }
                indexHumanNames(cask["name"], entry: entry, byName: &byName, byNorm: &byNorm)
            }
            return CaskCatalog(byAppName: byApp, byDisplayName: byName, byNormalizedName: byNorm)
        }

        return CaskCatalog(byAppName: byApp, byDisplayName: byName, byNormalizedName: byNorm)
    }

    // Index every .app filename this cask provides (6.x raw_artifacts form: a
    // list of [stanza, value] pairs). Keys off `:app` stanzas, and ALSO mines
    // `:uninstall`/`:zap` delete/trash paths for "/Applications/*.app" so
    // pkg-based casks (e.g. OneDrive) still match a bundle by file name.
    private static func indexAppNames(rawArtifacts: Any?, entry: Entry, into byApp: inout [String: Entry]) {
        guard let stanzas = rawArtifacts as? [[Any]] else { return }
        for pair in stanzas {
            guard pair.count >= 2, let kind = pair[0] as? String else { continue }
            switch kind {
            case ":app":
                if let apps = pair[1] as? [Any] {
                    for case let name as String in apps {
                        register(appFileName: name, entry: entry, into: &byApp)
                    }
                }
            case ":uninstall", ":zap":
                if let dict = pair[1] as? [String: Any] {
                    for value in dict.values { collectAppPaths(value, entry: entry, into: &byApp) }
                }
            default:
                continue
            }
        }
    }

    // Recursively collect "/…/Foo.app" paths from a delete/trash value (String
    // or [String]) and register their last path component as an app filename.
    private static func collectAppPaths(_ value: Any, entry: Entry, into byApp: inout [String: Entry]) {
        if let s = value as? String {
            if s.lowercased().hasSuffix(".app") {
                register(appFileName: (s as NSString).lastPathComponent, entry: entry, into: &byApp)
            }
        } else if let arr = value as? [Any] {
            for item in arr { collectAppPaths(item, entry: entry, into: &byApp) }
        }
    }

    // Register an app filename (lowercased). Skips wildcard paths; first-write
    // wins so an authoritative `:app` match isn't clobbered by a delete path.
    private static func register(appFileName: String, entry: Entry, into byApp: inout [String: Entry]) {
        let key = appFileName.lowercased()
        guard !key.isEmpty, !key.contains("*") else { return }
        if byApp[key] == nil { byApp[key] = entry }
    }

    // Index a cask's human names ("OneDrive", "VS Code") into the display-name
    // map AND the normalized map. Accepts the 6.x `names` or legacy `name` array.
    private static func indexHumanNames(_ names: Any?, entry: Entry,
                                        byName: inout [String: Entry],
                                        byNorm: inout [String: Entry]) {
        guard let names = names as? [Any] else { return }
        for case let n as String in names {
            let lower = n.lowercased()
            if byName[lower] == nil { byName[lower] = entry }
            let nkey = normalize(n)
            if !nkey.isEmpty, byNorm[nkey] == nil { byNorm[nkey] = entry }
        }
    }
}
