import Foundation

nonisolated struct CaskAnalyticsEntry: Codable, Sendable {
    let cask: String
    let count: String

    var installCount: Int {
        Int(count.replacingOccurrences(of: ",", with: "")) ?? 0
    }
}

// NOTE: No explicit CodingKeys here. BrewAPIService's decoder uses
// .convertFromSnakeCase, which maps total_items -> totalItems, etc. Declaring
// explicit snake_case CodingKeys at the same time double-maps the keys and
// makes decoding fail with "key not found", so we rely solely on the strategy.
nonisolated struct CaskAnalyticsResponse: Codable, Sendable {
    let category: String
    let totalItems: Int
    let startDate: String
    let endDate: String
    let totalCount: Int
    let formulae: [String: [CaskAnalyticsEntry]]
}

nonisolated struct FormulaAnalyticsItem: Codable, Sendable {
    let number: Int
    let formula: String
    let count: String
    let percent: String

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
