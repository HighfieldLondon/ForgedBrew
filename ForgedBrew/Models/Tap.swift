import Foundation

// MARK: - Tap
//
// A Homebrew "tap" is an additional source repository of formulae/casks beyond
// the built-in homebrew/core + homebrew/cask catalogs. Power users add taps
// (e.g. `brew tap user/repo`) to install software that isn't in the default
// catalog. This model is decoded from `brew tap-info <name> --json`.
//
// We surface only the taps the user has actually added (via `brew tap` with no
// args), then show — per tap — which of the user's INSTALLED packages came from
// it, by intersecting the tap's formula_names / cask_tokens with the installed
// inventory. Untapping does NOT uninstall those apps; it only removes the
// source repo, so the app keeps working but no longer updates from that tap.

struct Tap: Identifiable, Hashable, Sendable {
    // "user/repo", e.g. "yuzeguitarist/deck". Unique → stable id.
    let name: String
    let user: String
    let repo: String
    // Official Homebrew taps (homebrew/core, homebrew/cask). We mark these so
    // the UI can warn against removing them.
    let official: Bool
    // GitHub (or other) remote URL for the "View repository" link.
    let remote: String?
    // Human-readable relative time of the tap's last commit, e.g. "4 weeks ago".
    let lastCommit: String?
    // Fully-qualified package identifiers this tap provides.
    let formulaNames: [String]
    let caskTokens: [String]

    var id: String { name }

    // The catalog tokens a tap provides are fully-qualified ("user/repo/token")
    // for casks. We also keep the bare leaf token so we can match against the
    // user's installed inventory (which stores bare tokens for the default
    // catalog and qualified ones for third-party taps).
    var providedTokens: [String] { formulaNames + caskTokens }

    // The repo host label for display (e.g. "GitHub").
    var remoteHostLabel: String? {
        guard let remote, let host = URL(string: remote)?.host else { return nil }
        return host
    }
}

// MARK: - tap-info JSON decoding

// Mirrors the shape of one element of `brew tap-info <name> --json`.
struct BrewTapInfo: Decodable {
    let name: String
    let user: String
    let repo: String
    let official: Bool
    let remote: String?
    let lastCommit: String?
    let formulaNames: [String]
    let caskTokens: [String]

    enum CodingKeys: String, CodingKey {
        case name, user, repo, official, remote
        case lastCommit = "last_commit"
        case formulaNames = "formula_names"
        case caskTokens = "cask_tokens"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        user = (try? c.decode(String.self, forKey: .user)) ?? ""
        repo = (try? c.decode(String.self, forKey: .repo)) ?? ""
        official = (try? c.decode(Bool.self, forKey: .official)) ?? false
        remote = try? c.decodeIfPresent(String.self, forKey: .remote)
        lastCommit = try? c.decodeIfPresent(String.self, forKey: .lastCommit)
        formulaNames = (try? c.decode([String].self, forKey: .formulaNames)) ?? []
        caskTokens = (try? c.decode([String].self, forKey: .caskTokens)) ?? []
    }

    nonisolated func toTap() -> Tap {
        Tap(
            name: name,
            user: user,
            repo: repo,
            official: official,
            remote: remote,
            lastCommit: lastCommit,
            formulaNames: formulaNames,
            caskTokens: caskTokens
        )
    }
}
