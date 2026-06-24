import Foundation
import SwiftUI

@MainActor
@Observable
final class HomeViewModel {
    var featuredCask: CaskMetadata? = nil
    var trendingCasks: [CaskMetadata] = []
    var allTimePopular: [CaskMetadata] = []
    var isLoading: Bool = false

    init() {}

    func load(db: DatabaseManager) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let allCasks = try await db.fetchAllCasks()

            // 1. Trending: most-installed over the last 30 days (recent momentum).
            let byTrending = allCasks.sorted { $0.installCount30d > $1.installCount30d }
            trendingCasks = Array(byTrending.prefix(10))

            // 2. 3-Month Trend: most-installed over the last 90 days (sustained
            // popularity). Replaces the old "Recently Updated" list, which sorted
            // by tapGitHead (a meaningless git commit hash) and duplicated trending.
            let byAllTime = allCasks.sorted { $0.installCount90d > $1.installCount90d }
            allTimePopular = Array(byAllTime.prefix(10))

            // 3. Featured
            featuredCask = trendingCasks.first
        } catch {
            // Non-fatal: leave lists empty and log so failures are diagnosable.
            print("[HomeViewModel] Failed to load home data: \(error)")
        }
    }
}
