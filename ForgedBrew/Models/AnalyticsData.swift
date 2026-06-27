//
//  AnalyticsData.swift
//  ForgedBrew
//
//  DTOs for Homebrew's install-analytics endpoints (formulae.brew.sh/api/
//  analytics/...). These feed the popularity sort signals (30/90/365-day install
//  counts) stamped onto CaskMetadata. Casks and formulae use slightly different
//  response shapes, hence the parallel pairs below.
//
//  Wire quirk shared by every type here: the API returns install counts as
//  comma-grouped STRINGS ("1,234,567"), not numbers — so each entry parses its
//  own `installCount: Int` by stripping commas, defaulting to 0 on garbage.
//

import Foundation

/// One cask's install tally within a CaskAnalyticsResponse bucket.
nonisolated struct CaskAnalyticsEntry: Codable, Sendable {
    let cask: String
    /// Comma-grouped install count as delivered by the API ("1,234"). Use
    /// `installCount` for the parsed integer.
    let count: String

    // Strip the thousands separators the API embeds and parse to Int; 0 on
    // failure so a malformed row can't break the whole decode.
    var installCount: Int {
        Int(count.replacingOccurrences(of: ",", with: "")) ?? 0
    }
}

// NOTE: No explicit CodingKeys here. BrewAPIService's decoder uses
// .convertFromSnakeCase, which maps total_items -> totalItems, etc. Declaring
// explicit snake_case CodingKeys at the same time double-maps the keys and
// makes decoding fail with "key not found", so we rely solely on the strategy.
/// A full cask-analytics response for one time window. Despite the name, the
/// keyed payload is `formulae: [token: [entry]]` — the API reuses that key for
/// casks too (each token usually maps to a single-element array).
nonisolated struct CaskAnalyticsResponse: Codable, Sendable {
    let category: String
    let totalItems: Int
    let startDate: String
    let endDate: String
    let totalCount: Int
    let formulae: [String: [CaskAnalyticsEntry]]
}

/// One formula's install tally within a FormulaAnalyticsResponse. Unlike the
/// cask shape, formula analytics arrive as a flat ranked list (`number` is the
/// rank, `percent` the share of total installs).
nonisolated struct FormulaAnalyticsItem: Codable, Sendable {
    let number: Int
    let formula: String
    /// Comma-grouped install count string; see `installCount` for the integer.
    let count: String
    let percent: String

    // Same comma-stripping parse as CaskAnalyticsEntry; 0 on failure.
    var installCount: Int {
        Int(count.replacingOccurrences(of: ",", with: "")) ?? 0
    }
}

// See note on CaskAnalyticsResponse: no explicit CodingKeys — the decoder's
// .convertFromSnakeCase strategy handles total_items/start_date/etc.
nonisolated struct FormulaAnalyticsResponse: Codable, Sendable {
    let category: String
    let totalItems: Int
    let startDate: String
    let endDate: String
    let totalCount: Int
    let items: [FormulaAnalyticsItem]
}
