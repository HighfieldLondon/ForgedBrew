import Foundation
@preconcurrency import CoreSpotlight
import UniformTypeIdentifiers

// Indexes installed packages into macOS Spotlight via CoreSpotlight so the user
// can find their installed apps (and jump back into ForgedBrew) from a system-wide
// Spotlight search.
//
// Each installed package becomes a CSSearchableItem keyed by its stable id
// ("cask:rectangle" / "formula:git"). Where we have catalog metadata for the
// token we enrich the entry with the human display name + description; otherwise
// we fall back to the token. The whole installed set lives under one domain
// identifier so we can wipe + re-index cleanly on every refresh.
@MainActor
enum SpotlightIndexer {
    static let domainIdentifier = "com.highfieldlondon.ForgedBrew.installed"

    // Re-indexes the full installed set. `casks` is the current catalog, used to
    // resolve display names / descriptions by token. Failures are non-fatal —
    // Spotlight indexing is best-effort and must never break a refresh.
    static func index(
        packages: [InstalledPackage],
        casks: [CaskMetadata]
    ) {
        let index = CSSearchableIndex.default()

        // Build a token → cask lookup once for enrichment.
        var caskByToken: [String: CaskMetadata] = [:]
        for cask in casks {
            caskByToken[cask.token] = cask
        }

        let items: [CSSearchableItem] = packages.map { pkg in
            let cask = caskByToken[pkg.token]

            let attributes = CSSearchableItemAttributeSet(contentType: .application)
            // CaskMetadata.name is [String]; displayName resolves to name.first ?? token.
            attributes.title = cask?.displayName ?? pkg.token
            attributes.contentDescription = cask?.desc
            attributes.version = pkg.installedVersion

            // Keywords help fuzzy matches: token, display name, and "Homebrew".
            var keywords: [String] = [pkg.token, "Homebrew", "ForgedBrew"]
            if let name = cask?.displayName { keywords.append(name) }
            attributes.keywords = keywords

            return CSSearchableItem(
                uniqueIdentifier: pkg.id,
                domainIdentifier: domainIdentifier,
                attributeSet: attributes
            )
        }

        // Clear the domain first so uninstalled packages don't linger, then
        // index the current set.
        index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in
            guard !items.isEmpty else { return }
            index.indexSearchableItems(items) { _ in }
        }
    }

    // Removes all ForgedBrew-indexed installed items (e.g. on a full reset).
    static func clearIndex() {
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in }
    }
}
