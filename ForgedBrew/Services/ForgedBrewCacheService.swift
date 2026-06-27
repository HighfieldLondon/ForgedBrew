import Foundation
import AppKit
import CryptoKit

// Shared on-disk cache for ForgedBrew's downloaded media: README/web screenshots
// and homepage favicons. Everything lives under a single Application Support
// directory so the Maintenance screen can report one total size and wipe it
// all with one "Clear ForgedBrew Cache" action.
//
// Layout:
//   <AppSupport>/ForgedBrew/Cache/
//     screenshots/<token>/<version-hash>/<index>.jpg
//     favicons/<host-hash>.png
//
// Design notes:
//   • Screenshots are downscaled + re-encoded to JPEG on save so the cache
//     stays small (the user opted for downscale, no hard cap).
//   • Screenshot sets are keyed by token + version, so a cask version bump
//     naturally invalidates the old set (a different folder) and triggers a
//     re-fetch. Stale version folders are pruned lazily when we write a new one.
//   • This is an actor: all disk I/O is serialized off the main thread, and the
//     type is safe to share (`ForgedBrewCacheService.shared`) across views.
actor ForgedBrewCacheService {
    static let shared = ForgedBrewCacheService()

    private let fm = FileManager.default

    private init() {}

    // MARK: - Directory layout

    // Root cache directory, created on demand. Falls back to a temp dir if
    // Application Support is somehow unavailable (never expected on macOS).
    private var rootURL: URL {
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("ForgedBrew", isDirectory: true)
            .appendingPathComponent("Cache", isDirectory: true)
    }

    private var screenshotsRoot: URL {
        rootURL.appendingPathComponent("screenshots", isDirectory: true)
    }

    private var faviconsRoot: URL {
        rootURL.appendingPathComponent("favicons", isDirectory: true)
    }

    private var thumbnailsRoot: URL {
        rootURL.appendingPathComponent("thumbnails", isDirectory: true)
    }

    private func ensureDir(_ url: URL) {
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // Short, filesystem-safe hash for arbitrary strings (versions, hosts).
    private func hash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // Token sanitized for use as a directory name. Cask tokens are already
    // lowercase-hyphenated, but we guard against any stray path characters.
    private func safeToken(_ token: String) -> String {
        token.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
    }

    // MARK: - Screenshots

    private func screenshotDir(token: String, version: String?) -> URL {
        let versionKey = hash(version ?? "noversion")
        return screenshotsRoot
            .appendingPathComponent(safeToken(token), isDirectory: true)
            .appendingPathComponent(versionKey, isDirectory: true)
    }

    // Returns cached screenshot file URLs for this token+version if present,
    // sorted by their numeric index. An empty array is ambiguous on its own
    // (could be "never fetched" or "resolved to zero images"); callers
    // disambiguate via `hasCachedScreenshotResult`, which checks for the
    // ".resolved" marker written by `storeScreenshots`.
    func cachedScreenshots(token: String, version: String?) -> [URL] {
        let dir = screenshotDir(token: token, version: version)
        guard fm.fileExists(atPath: dir.path) else { return [] }

        // Only the numbered "NN.jpg" image files count as screenshots; the
        // ".resolved" marker (if any) is ignored by the extension filter below.
        let entries = (try? fm.contentsOfDirectory(at: dir,
                                                   includingPropertiesForKeys: nil)) ?? []
        let images = entries
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return images
    }

    // True if we have already resolved screenshots for this token+version
    // (either some images or an explicit empty marker), so the caller can skip
    // the network entirely until the version changes.
    func hasCachedScreenshotResult(token: String, version: String?) -> Bool {
        let dir = screenshotDir(token: token, version: version)
        let marker = dir.appendingPathComponent(".resolved")
        return fm.fileExists(atPath: marker.path)
    }

    // Downloads each remote image, downscales + re-encodes to JPEG, and writes
    // the set to this token+version's folder. Older version folders for the
    // same token are pruned. Writes a ".resolved" marker (only when every
    // candidate was stored, so a transient failure on any image doesn't poison
    // the cache with a partial set) so we don't re-fetch until the version
    // changes. Returns the local file URLs in order.
    @discardableResult
    func storeScreenshots(remoteURLs: [URL],
                          token: String,
                          version: String?,
                          maxWidth: CGFloat = 1000,
                          jpegQuality: CGFloat = 0.8) async -> [URL] {
        let dir = screenshotDir(token: token, version: version)

        // Prune other version folders for this token first.
        pruneOldScreenshotVersions(token: token, keep: dir)

        ensureDir(dir)

        var localURLs: [URL] = []
        var index = 0
        for remote in remoteURLs {
            guard let data = try? await downloadData(remote),
                  let downscaled = downscaledJPEG(from: data, maxWidth: maxWidth, quality: jpegQuality)
            else { continue }
            let dest = dir.appendingPathComponent(String(format: "%02d.jpg", index))
            if (try? downscaled.write(to: dest, options: .atomic)) != nil {
                localURLs.append(dest)
                index += 1
            }
        }

        // Write the resolved marker so we skip the network until the cask
        // version changes — but ONLY when the result is trustworthy, i.e. EVERY
        // candidate was stored. Two cases are legitimate to cache:
        //   • there were no candidates at all (nothing to fetch), or
        //   • we successfully stored every candidate image.
        // If even one candidate failed (e.g. a transient DNS or network hiccup,
        // or a slow render service), we must NOT write the marker — otherwise a
        // one-time partial failure poisons the cache forever: a "resolved" set
        // that's missing images, or a "resolved-empty" set when all failed, with
        // no retry until the version bumps. Leaving the marker unset lets the
        // next visit retry the missing ones. (This still covers the original
        // "all failed → don't poison the cache" case, since all-failed is just
        // the extreme of any-failed.)
        let allSucceeded = localURLs.count == remoteURLs.count
        if allSucceeded {
            let marker = dir.appendingPathComponent(".resolved")
            try? Data().write(to: marker)
        }

        return localURLs
    }

    // Removes every screenshot version folder for `token` except `keep`.
    private func pruneOldScreenshotVersions(token: String, keep: URL) {
        let tokenDir = screenshotsRoot.appendingPathComponent(safeToken(token), isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: tokenDir,
                                                        includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Favicons

    // Returns the local favicon file URL for a host if cached, else nil.
    func cachedFavicon(host: String) -> URL? {
        let dest = faviconsRoot.appendingPathComponent("\(hash(host)).png")
        return fm.fileExists(atPath: dest.path) ? dest : nil
    }

    // Downloads a favicon for `host` (the caller supplies the remote URL,
    // typically Google's favicon service) and stores it as PNG. Returns the
    // local file URL, or nil on failure.
    @discardableResult
    func storeFavicon(remoteURL: URL, host: String) async -> URL? {
        ensureDir(faviconsRoot)
        guard let data = try? await downloadData(remoteURL),
              let image = NSImage(data: data),
              let png = pngData(from: image)
        else { return nil }
        let dest = faviconsRoot.appendingPathComponent("\(hash(host)).png")
        guard (try? png.write(to: dest, options: .atomic)) != nil else { return nil }
        return dest
    }

    // MARK: - Card thumbnails
    //
    // A small per-cask banner image shown on grid cards (Phase B). Distinct from
    // the larger detail-page screenshot set: thumbnails are a single downscaled
    // image per token, keyed only by token (the GitHub social-preview banner is
    // stable across cask versions, so we don't version-key it — a card thumbnail
    // doesn't need version invalidation the way the detail screenshot set does).
    // Cache-first, like favicons: callers check `cachedThumbnail` before any
    // network, and a ".none" marker records "we looked, there isn't one" so a
    // cask without a banner never re-fetches.

    // Local thumbnail file URL for a token if a real image is cached, else nil.
    func cachedThumbnail(token: String) -> URL? {
        let dest = thumbnailsRoot.appendingPathComponent("\(safeToken(token)).jpg")
        return fm.fileExists(atPath: dest.path) ? dest : nil
    }

    // True once we've resolved this token's thumbnail (either stored an image or
    // wrote a ".none" marker), so the caller can skip the network entirely.
    func hasResolvedThumbnail(token: String) -> Bool {
        let img = thumbnailsRoot.appendingPathComponent("\(safeToken(token)).jpg")
        let none = thumbnailsRoot.appendingPathComponent("\(safeToken(token)).none")
        return fm.fileExists(atPath: img.path) || fm.fileExists(atPath: none.path)
    }

    // Downloads a card thumbnail from `remoteURL` (typically a GitHub
    // social-preview banner — a plain CDN image, NOT a GitHub API call, so it
    // costs nothing against the 60/hr API cap), downscales + re-encodes to JPEG,
    // and stores it as `<token>.jpg`. On any failure writes a `.none` marker so
    // we don't retry. Returns the local file URL, or nil when none was stored.
    @discardableResult
    func storeThumbnail(remoteURL: URL,
                        token: String,
                        maxWidth: CGFloat = 480,
                        jpegQuality: CGFloat = 0.8) async -> URL? {
        ensureDir(thumbnailsRoot)
        let dest = thumbnailsRoot.appendingPathComponent("\(safeToken(token)).jpg")
        let noneMarker = thumbnailsRoot.appendingPathComponent("\(safeToken(token)).none")

        guard let data = try? await downloadData(remoteURL),
              let downscaled = downscaledJPEG(from: data, maxWidth: maxWidth, quality: jpegQuality),
              (try? downscaled.write(to: dest, options: .atomic)) != nil
        else {
            try? Data().write(to: noneMarker)
            return nil
        }
        return dest
    }

    // Promotes an already-downloaded detail-page screenshot (a local JPEG in
    // the screenshots cache) into this token's card thumbnail slot, downscaling
    // it to the card size. Used so a cask the user has opened shows a real
    // README screenshot on its grid card instead of the generic social-preview
    // banner — at ZERO network cost, since the source image is already on disk.
    // Returns the stored thumbnail URL, or nil on failure (no ".none" marker is
    // written here: a failure shouldn't block the later banner fallback).
    @discardableResult
    func storeThumbnail(fromLocal localImage: URL,
                        token: String,
                        maxWidth: CGFloat = 480,
                        jpegQuality: CGFloat = 0.8) async -> URL? {
        ensureDir(thumbnailsRoot)
        let dest = thumbnailsRoot.appendingPathComponent("\(safeToken(token)).jpg")
        guard let data = try? Data(contentsOf: localImage),
              let downscaled = downscaledJPEG(from: data, maxWidth: maxWidth, quality: jpegQuality),
              (try? downscaled.write(to: dest, options: .atomic)) != nil
        else { return nil }
        return dest
    }

    // The first cached detail-page screenshot for this token+version, if any.
    // A convenience over cachedScreenshots(...).first for the card thumbnail
    // path, which only wants the lead (best) README image.
    func firstCachedScreenshot(token: String, version: String?) -> URL? {
        cachedScreenshots(token: token, version: version).first
    }

    // MARK: - Size + clearing (for the Maintenance screen)

    // Total bytes used by the whole ForgedBrew cache (screenshots + favicons).
    func totalCacheSize() -> Int64 {
        directorySize(rootURL)
    }

    // Human-readable size string, e.g. "42.3 MB".
    func totalCacheSizeString() -> String {
        ByteCountFormatter.string(fromByteCount: totalCacheSize(), countStyle: .file)
    }

    // Deletes the entire ForgedBrew cache (screenshots + favicons). Returns the
    // number of bytes freed.
    @discardableResult
    func clearAll() -> Int64 {
        let freed = totalCacheSize()
        try? fm.removeItem(at: rootURL)
        return freed
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            )
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - Helpers

    // Per-image download timeout. URLSession's default request timeout is 60s,
    // which made the Screenshots tab spin for up to a minute before falling
    // back when a candidate stalled — most often the thum.io page-render
    // service or a hotlink-protected image. 15s is generous enough for a real
    // page render to finish yet short enough that the fallback chain feels
    // responsive on both app and formula cards.
    private static let screenshotDownloadTimeout: TimeInterval = 15

    private func downloadData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("ForgedBrew/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.screenshotDownloadTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // Decodes image bytes, downscales to `maxWidth` (preserving aspect ratio,
    // never upscaling), and re-encodes as JPEG at `quality`. Returns nil on any
    // failure. Uses NSBitmapImageRep for deterministic pixel output.
    private nonisolated func downscaledJPEG(from data: Data, maxWidth: CGFloat, quality: CGFloat) -> Data? {
        guard let source = NSImage(data: data) else { return nil }
        let pixelSize = source.pixelSize ?? source.size
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }

        let scale = min(1.0, maxWidth / pixelSize.width)
        let targetW = Int((pixelSize.width * scale).rounded())
        let targetH = Int((pixelSize.height * scale).rounded())
        guard targetW > 0, targetH > 0 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetW,
            pixelsHigh: targetH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: targetW, height: targetH)

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
            from: NSRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1.0
        )
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private nonisolated func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// Pixel dimensions of an NSImage (vs. its point `size`), read from the largest
// bitmap representation. Falls back to nil when no bitmap rep is available.
// Marked nonisolated so the off-main-actor downscale path can read it.
private extension NSImage {
    nonisolated var pixelSize: NSSize? {
        var best: NSSize? = nil
        for rep in representations {
            let w = rep.pixelsWide, h = rep.pixelsHigh
            if w > 0, h > 0 {
                let candidate = NSSize(width: w, height: h)
                if best == nil || candidate.width > best!.width {
                    best = candidate
                }
            }
        }
        return best
    }
}
