//
//  HomeViewModel.swift
//  ForgedBrew
//
//  Backs the Home / Discover feed (HomeView). A thin, in-memory ranking layer:
//  it reads the full cask catalog from the local DB and derives the three
//  ranked lists the home page shows. No network and no pagination of its own —
//  the heavy catalog refresh lives in AppDataService; this VM only sorts and
//  slices what is already on disk.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class HomeViewModel {
    /// The single app shown in the hero card — currently the top trending cask.
    var featuredCask: CaskMetadata? = nil
    /// Top 10 by 30-day install momentum (the "Currently Trending" list/grid).
    var trendingCasks: [CaskMetadata] = []
    /// Top 10 by 90-day installs (the "3-Month Trend" list). Named "allTime…"
    /// for historical reasons; it is the 90-day window, not all-time.
    var allTimePopular: [CaskMetadata] = []
    /// True while load() is fetching + ranking; drives HomeView's spinner.
    var isLoading: Bool = false

    init() {}

    /// Rebuilds all three home lists from the on-disk catalog. Pure in-memory
    /// sort/slice work — fast enough to re-run on appear and after a refresh.
    /// Errors are swallowed (lists left empty) so a transient DB hiccup never
    /// blanks or crashes the landing page.
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
