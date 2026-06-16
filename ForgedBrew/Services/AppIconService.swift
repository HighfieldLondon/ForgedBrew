import AppKit
import SwiftUI

// Resolves real application icons for installed casks by scanning the
// standard macOS application directories and matching bundle names against
// a cask's display name / token. Results are cached so repeated lookups
// (e.g. while scrolling a grid) are cheap. Lookups never throw — a missing
// or unmatched app simply yields nil, and callers fall back to the
// generated placeholder tile.
@MainActor
final class AppIconService {
    static let shared = AppIconService()

    // Normalized app-bundle-name -> bundle URL (e.g. "visualstudiocode" -> .../Visual Studio Code.app)
    private var bundleIndex: [String: URL] = [:]
    private var indexBuilt = false

    // Cache of resolved icons keyed by cask token. NSImage? so we remember
    // negative results too and avoid re-scanning the disk for misses.
    private var iconCache: [String: NSImage?] = [:]

    // In-memory cache of favicons resolved for not-installed apps, keyed by
    // homepage host. NSImage? remembers misses so we don't re-hit the network.
    private var faviconCache: [String: NSImage?] = [:]

    // Cache of icons resolved directly from a file path (used by the Mac
    // Store/Other Apps rows, which already know each app's bundle path).
    private var pathIconCache: [String: NSImage?] = [:]

    private init() {}

    // Standard locations where .app bundles live.
    private var searchDirectories: [URL] {
        let fm = FileManager.default
        var dirs: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications")
        ]
        let home = fm.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent("Applications"))
        return dirs
    }

    // Lowercased, alphanumeric-only form used for fuzzy matching.
    private func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    // Builds the bundle-name index once. Cheap: one shallow listing per dir.
    private func buildIndexIfNeeded() {
        guard !indexBuilt else { return }
        indexBuilt = true
        let fm = FileManager.default
        for dir in searchDirectories {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension == "app" {
                let base = url.deletingPathExtension().lastPathComponent
                let key = normalize(base)
                guard !key.isEmpty else { continue }
                // First write wins (prefer /Applications, listed first).
                if bundleIndex[key] == nil {
                    bundleIndex[key] = url
                }
            }
        }
    }

    // Finds the best-matching installed .app for the given names.
    private func matchBundle(displayName: String, token: String) -> URL? {
        buildIndexIfNeeded()

        let candidates = [displayName, token].map(normalize).filter { !$0.isEmpty }
        // 1. Exact normalized match.
        for c in candidates {
            if let url = bundleIndex[c] { return url }
        }
        // 2. Token with hyphens removed is already normalized; try prefix/contains
        //    against bundle names for cases like "iterm2" vs "iTerm".
        for c in candidates {
            if let hit = bundleIndex.first(where: { $0.key == c || $0.key.hasPrefix(c) || c.hasPrefix($0.key) }) {
                return hit.value
            }
        }
        return nil
    }

    // Returns the icon for a cask if its app is installed, else nil.
    func icon(token: String, displayName: String) -> NSImage? {
        if let cached = iconCache[token] {
            return cached
        }
        let result: NSImage?
        if let url = matchBundle(displayName: displayName, token: token) {
            result = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            result = nil
        }
        iconCache[token] = result
        return result
    }

    // Async, OFF-MAIN-THREAD icon resolution — the scroll-freeze fix.
    //
    // The synchronous `icon(token:displayName:)` above runs `NSWorkspace.icon(
    // forFile:)` and a directory scan on the main actor. Calling it from a
    // SwiftUI `.task` does NOT move that work off the main thread (a `.task`
    // body runs on the main actor), so a fast scroll-fling that realizes many
    // cards at once fires dozens of those synchronous lookups per frame and the
    // UI freezes.
    //
    // This method instead:
    //   1. Returns the cached answer immediately on a hit (O(1), main actor).
    //   2. On a miss, hops to a DETACHED background task to do the path match +
    //      NSWorkspace icon read (both safe off-main), then stores the result
    //      back in the cache on the main actor and returns it.
    // The detached work uses a snapshot of the bundle index, building it on the
    // background thread the first time so the main thread never blocks on the
    // directory scan either.
    func resolvedIcon(token: String, displayName: String) async -> NSImage? {
        if let cached = iconCache[token] { return cached }

        // Ensure the bundle index exists (built off-main on first use).
        if !indexBuilt {
            let dirs = searchDirectories
            let built: [String: URL] = await Task.detached(priority: .utility) {
                Self.buildIndex(searchDirectories: dirs)
            }.value
            // Another concurrent resolve may have built it already; keep the
            // first one that landed.
            if !indexBuilt {
                bundleIndex = built
                indexBuilt = true
            }
        }

        // Re-check the cache (a concurrent resolve for the same token may have
        // filled it while we were building the index).
        if let cached = iconCache[token] { return cached }

        let indexSnapshot = bundleIndex
        let matchedPath: String? = await Task.detached(priority: .utility) {
            Self.matchBundlePath(displayName: displayName, token: token, index: indexSnapshot)
        }.value

        let result: NSImage? = await Task.detached(priority: .utility) {
            guard let matchedPath else { return nil }
            // NSWorkspace.icon(forFile:) is safe to call off the main thread.
            return NSWorkspace.shared.icon(forFile: matchedPath)
        }.value

        iconCache[token] = result
        return result
    }

    // Decodes an NSImage from a local file URL on a DETACHED background task.
    // NSImage(contentsOf:) decodes pixel data, which is too heavy for the main
    // thread when many cards realize at once during a fast scroll — so callers
    // on the hot path (card thumbnails) use this instead of decoding inline.
    nonisolated static func decodeImage(at url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
    }

    // Cache-only peek for a path-resolved icon (hot scrolling path, O(1)).
    func cachedIcon(path: String) -> NSImage?? {
        pathIconCache[path]
    }

    // Async, OFF-MAIN-THREAD icon resolution for a KNOWN bundle path. Same
    // freeze fix as resolvedIcon but for callers that already have the .app
    // path (the non-Homebrew app rows). NSWorkspace.icon(forFile:) runs on a
    // detached background task; the result is cached on the main actor.
    func resolvedIcon(path: String) async -> NSImage? {
        if let cached = pathIconCache[path] { return cached }
        let result: NSImage? = await Task.detached(priority: .utility) {
            NSWorkspace.shared.icon(forFile: path)
        }.value
        pathIconCache[path] = result
        return result
    }

    // Nonisolated index builder used by the detached resolve path. Mirrors
    // buildIndexIfNeeded() but takes its inputs as parameters so it can run on a
    // background thread without touching actor state.
    nonisolated private static func buildIndex(searchDirectories: [URL]) -> [String: URL] {
        let fm = FileManager.default
        var index: [String: URL] = [:]
        for dir in searchDirectories {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension == "app" {
                let base = url.deletingPathExtension().lastPathComponent
                let key = normalizeStatic(base)
                guard !key.isEmpty else { continue }
                if index[key] == nil { index[key] = url }
            }
        }
        return index
    }

    // Nonisolated matcher used by the detached resolve path. Mirrors
    // matchBundle(displayName:token:) against a provided index snapshot.
    nonisolated private static func matchBundlePath(displayName: String, token: String, index: [String: URL]) -> String? {
        let candidates = [displayName, token].map(normalizeStatic).filter { !$0.isEmpty }
        for c in candidates {
            if let url = index[c] { return url.path }
        }
        for c in candidates {
            if let hit = index.first(where: { $0.key == c || $0.key.hasPrefix(c) || c.hasPrefix($0.key) }) {
                return hit.value.path
            }
        }
        return nil
    }

    // Nonisolated normalize (same rule as the instance `normalize`).
    nonisolated private static func normalizeStatic(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    // Cache-ONLY peek used on the hot scrolling path. Returns the already-cached
    // icon (or cached negative result) WITHOUT ever touching the disk or calling
    // NSWorkspace. The outer Optional tells callers "do I have an answer yet?":
    //   - nil            -> not resolved yet (resolve once via `icon(...)` in a task)
    //   - .some(nil)     -> resolved, no local icon (use favicon/placeholder)
    //   - .some(image)   -> resolved local icon
    // This keeps card `body` evaluations O(1) during a fast scroll-fling, so we
    // never fire dozens of synchronous NSWorkspace.icon(forFile:) lookups per
    // frame on the main thread — the source of the scroll freeze.
    func cachedIcon(token: String) -> NSImage?? {
        iconCache[token]
    }

    // Invalidates caches (call after an install/uninstall changes /Applications).
    // Note: the favicon cache is intentionally NOT cleared here — favicons don't
    // change when an app is installed/removed, and they're persisted on disk.
    func invalidate() {
        bundleIndex.removeAll()
        iconCache.removeAll()
        indexBuilt = false
    }

    // MARK: - Favicon fallback (not-installed apps)

    // Normalizes a homepage URL string to a bare host (lowercased, no leading
    // "www."). Returns nil when there's no usable host.
    private func host(from homepage: String?) -> String? {
        guard let homepage,
              let url = URL(string: homepage),
              let h = url.host else { return nil }
        var host = h.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    // Resolves a homepage favicon for an app that has no local .app icon.
    // Checks the in-memory cache, then the on-disk ForgedBrew cache, then fetches
    // from Google's favicon service (which reliably returns a PNG for a domain)
    // and persists it. Returns nil when no homepage/host is available or the
    // fetch fails — callers then keep showing the lettered placeholder.
    func favicon(homepage: String?) async -> NSImage? {
        guard let host = host(from: homepage) else { return nil }

        if let cached = faviconCache[host] {
            return cached
        }

        // On-disk cache first.
        if let localURL = await ForgedBrewCacheService.shared.cachedFavicon(host: host),
           let image = NSImage(contentsOf: localURL) {
            faviconCache[host] = image
            return image
        }

        // Fetch + persist via the shared cache. 64px is crisp enough for the
        // 48pt grid tile and the 92pt detail header.
        guard let remote = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64") else {
            faviconCache[host] = NSImage?.none
            return nil
        }
        if let storedURL = await ForgedBrewCacheService.shared.storeFavicon(remoteURL: remote, host: host),
           let image = NSImage(contentsOf: storedURL) {
            faviconCache[host] = image
            return image
        }

        faviconCache[host] = NSImage?.none
        return nil
    }
}
