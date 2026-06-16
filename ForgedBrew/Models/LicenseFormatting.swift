import Foundation

// Shared SPDX → human-friendly license formatting.
//
// Both casks (license resolved from GitHub's `license.spdx_id`) and formulae
// (license straight from the Homebrew formula JSON) hand us raw SPDX strings
// like "Apache-2.0", "GPL-3.0-or-later", or compound expressions such as
// "MIT OR Apache-2.0". Those are technically correct but read poorly in a
// badge or stat card. This helper normalizes them to the clean type labels a
// user expects to see — "MIT", "Apache 2.0", "GPL 3.0" — surfacing the
// license *type* rather than the raw SPDX token.
//
// Kept SwiftUI-free (Models rule) and `nonisolated` so it's usable from any
// actor and from Codable/Sendable model types.
nonisolated enum LicenseFormatting {

    // SPDX ids we treat as "no real license" — GitHub already maps unknown
    // repos to "NOASSERTION", but we guard the rest defensively so callers can
    // honestly flag "Unknown" instead of printing a meaningless token.
    static let unknownMarkers: Set<String> = [
        "NOASSERTION", "NONE", "UNLICENSED", "UNKNOWN", ""
    ]

    // SPDX ids we consider proprietary / not open source, for filter logic.
    static let proprietaryMarkers: Set<String> = [
        "PROPRIETARY", "UNLICENSED", "NONE"
    ]

    // Exact-match friendly names for the SPDX ids that actually show up across
    // Homebrew casks & formulae. Anything not listed falls through to the
    // generic prettifier below, so we never *hide* a real license just because
    // it isn't in this table.
    private static let friendlyNames: [String: String] = [
        "MIT": "MIT",
        "MIT-0": "MIT",
        "BSD-2-CLAUSE": "BSD 2-Clause",
        "BSD-3-CLAUSE": "BSD 3-Clause",
        "BSD-3-CLAUSE-CLEAR": "BSD 3-Clause",
        "APACHE-2.0": "Apache 2.0",
        "GPL-2.0": "GPL 2.0",
        "GPL-2.0-ONLY": "GPL 2.0",
        "GPL-2.0-OR-LATER": "GPL 2.0+",
        "GPL-3.0": "GPL 3.0",
        "GPL-3.0-ONLY": "GPL 3.0",
        "GPL-3.0-OR-LATER": "GPL 3.0+",
        "LGPL-2.1": "LGPL 2.1",
        "LGPL-2.1-ONLY": "LGPL 2.1",
        "LGPL-2.1-OR-LATER": "LGPL 2.1+",
        "LGPL-3.0": "LGPL 3.0",
        "LGPL-3.0-ONLY": "LGPL 3.0",
        "LGPL-3.0-OR-LATER": "LGPL 3.0+",
        "AGPL-3.0": "AGPL 3.0",
        "AGPL-3.0-ONLY": "AGPL 3.0",
        "AGPL-3.0-OR-LATER": "AGPL 3.0+",
        "MPL-2.0": "MPL 2.0",
        "EPL-2.0": "EPL 2.0",
        "ISC": "ISC",
        "UNLICENSE": "Unlicense",
        "ZLIB": "zlib",
        "WTFPL": "WTFPL",
        "CC0-1.0": "CC0",
        "CC-BY-4.0": "CC BY 4.0",
        "CC-BY-SA-4.0": "CC BY-SA 4.0",
        "ARTISTIC-2.0": "Artistic 2.0",
        "BSL-1.0": "Boost 1.0",
        "OFL-1.1": "OFL 1.1",
        "PROPRIETARY": "Proprietary"
    ]

    // True when the raw SPDX string carries no real license signal.
    static func isUnknown(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return unknownMarkers.contains(trimmed.uppercased())
    }

    // The human-friendly license *type* for a raw SPDX string, or nil when the
    // license is genuinely unknown. Handles compound SPDX expressions
    // ("MIT OR Apache-2.0", "(MIT AND BSD-3-Clause)") by formatting each part.
    static func friendlyType(for raw: String?) -> String? {
        guard let raw, !isUnknown(raw) else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // Compound expression: split on the SPDX operators (case-insensitive)
        // and format each side. AND => "+", OR => "/".
        let upper = cleaned.uppercased()
        if upper.contains(" OR ") || upper.contains(" AND ") || upper.contains(" WITH ") {
            let joiner = upper.contains(" AND ") ? " + " : " / "
            let pieces = splitCompound(cleaned)
            let mapped = pieces.map { prettifyAtom($0) }.filter { !$0.isEmpty }
            if !mapped.isEmpty { return mapped.joined(separator: joiner) }
        }

        return prettifyAtom(cleaned)
    }

    // Split a compound SPDX expression on OR/AND/WITH regardless of casing.
    private static func splitCompound(_ s: String) -> [String] {
        var current = ""
        var out: [String] = []
        let tokens = s.split(separator: " ").map(String.init)
        for tok in tokens {
            let upper = tok.uppercased()
            if upper == "OR" || upper == "AND" || upper == "WITH" {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current += current.isEmpty ? tok : " " + tok
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.count > 1 ? out : []
    }

    // Friendly name for a single (non-compound) SPDX id.
    private static func prettifyAtom(_ atom: String) -> String {
        let key = atom.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if key.isEmpty { return "" }
        if let friendly = friendlyNames[key] { return friendly }
        // Generic fallback: keep the original casing of the id but turn the
        // version-suffix dashes into spaces so e.g. "EUPL-1.2" → "EUPL 1.2".
        let original = atom.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dashRange = original.range(of: "-") {
            let head = String(original[..<dashRange.lowerBound])
            let tail = String(original[dashRange.upperBound...]).replacingOccurrences(of: "-", with: " ")
            return "\(head) \(tail)"
        }
        return original
    }
}
