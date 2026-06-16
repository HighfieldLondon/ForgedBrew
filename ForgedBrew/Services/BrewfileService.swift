import Foundation

// A single line of meaning from a Brewfile: a tap, a formula, or a cask.
// `name` is the bare identifier (e.g. "git", "visual-studio-code", "homebrew/cask").
nonisolated enum BrewfileEntryKind: String, Sendable, Hashable {
    case tap
    case brew      // a formula
    case cask      // a cask
}

nonisolated struct BrewfileEntry: Identifiable, Sendable, Hashable {
    let kind: BrewfileEntryKind
    let name: String
    // Stable identity for SwiftUI lists.
    var id: String { "\(kind.rawValue):\(name)" }
}

// Pure, stateless Brewfile helpers. No actor isolation, no I/O here — generation
// and parsing are deterministic string transforms. File reading/writing and the
// install pipeline live in AppDataService so they can touch the CLI + DB.
nonisolated enum BrewfileService {

    // MARK: - Generate

    // Produces Brewfile text from the installed packages. Formulae come first
    // (as `brew "name"`), then casks (as `cask "token"`), each sorted
    // alphabetically for a stable, diff-friendly file. A leading
    // `tap "homebrew/cask"` line is included so the file is self-contained.
    static func generate(from packages: [InstalledPackage]) -> String {
        let formulae = packages
            .filter { $0.type == .formula }
            .map { $0.token }
            .sorted()
        let casks = packages
            .filter { $0.type == .cask }
            .map { $0.token }
            .sorted()

        var lines: [String] = []
        lines.append("tap \"homebrew/cask\"")
        if !formulae.isEmpty {
            lines.append("")
            for name in formulae {
                lines.append("brew \"\(name)\"")
            }
        }
        if !casks.isEmpty {
            lines.append("")
            for token in casks {
                lines.append("cask \"\(token)\"")
            }
        }
        // Trailing newline so the file is POSIX-friendly.
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Parse

    // Parses Brewfile text into entries. Handles the common `brew bundle` grammar:
    //   tap "homebrew/cask"
    //   brew "git"
    //   cask "visual-studio-code"
    // Tolerates: single or double quotes, optional commas/options after the name
    // (e.g. `brew "foo", args: ["with-bar"]` — we keep just "foo"), inline `#`
    // comments, full-line comments, and blank lines. Unknown verbs are skipped.
    // Duplicate entries (same kind+name) are collapsed, preserving first-seen order.
    static func parse(_ contents: String) -> [BrewfileEntry] {
        var seen = Set<String>()
        var result: [BrewfileEntry] = []

        for rawLine in contents.components(separatedBy: .newlines) {
            // Strip inline comments, then trim.
            var line = rawLine
            if let hashIndex = line.firstIndex(of: "#") {
                line = String(line[..<hashIndex])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Identify the verb (first token) and map to a kind.
            guard let spaceIndex = line.firstIndex(of: " ") else { continue }
            let verb = String(line[..<spaceIndex])
            let rest = String(line[line.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)

            let kind: BrewfileEntryKind
            switch verb {
            case "tap": kind = .tap
            case "brew": kind = .brew
            case "cask": kind = .cask
            default: continue   // mas, whalebrew, etc. — not supported, skip
            }

            // Pull the first quoted string out of `rest`. If there are no quotes,
            // fall back to the first whitespace/comma-delimited token.
            guard let name = firstQuotedOrToken(rest), !name.isEmpty else { continue }

            let entry = BrewfileEntry(kind: kind, name: name)
            if seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        return result
    }

    // Extracts the first quoted substring from `text` (single or double quotes).
    // If none is found, returns the first token up to a comma or whitespace.
    private static func firstQuotedOrToken(_ text: String) -> String? {
        // Find the first quote character of either style.
        if let openIndex = text.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
            let quoteChar = text[openIndex]
            let afterOpen = text.index(after: openIndex)
            if let closeIndex = text[afterOpen...].firstIndex(of: quoteChar) {
                return String(text[afterOpen..<closeIndex])
            }
        }
        // No quotes: take up to the first comma or whitespace.
        let token = text.prefix { $0 != "," && $0 != " " }
        let trimmed = String(token).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
