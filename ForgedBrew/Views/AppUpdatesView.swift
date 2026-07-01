import SwiftUI
import AppKit

// MARK: - AppUpdatesView
//
// The sidebar destination for NON-Homebrew app updates (Mac App Store +
// direct-download apps). It complements the brew "Updates" screen: that one
// owns Homebrew-managed packages; this one surfaces everything else that has an
// update available — detected via Sparkle appcasts, GitHub releases, and the
// `mas` CLI — so the user sees all pending updates in one place.
//
// These apps update themselves (via their own updater or the Mac App Store), so
// ForgedBrew does NOT try to update them — the screen is awareness that an update
// exists. Per row the user can Open App (jump to it and update from within) or
// Uninstall. This is our "App Updates" feature.

// MARK: - AppSortOrder
//
// How the Mac Store / Other Apps lists are ordered. Mirrors the Homebrew
// Installed screen's PackageSortOrder, but DEFAULTS to install date (newest
// first) per the user's request — the Mac apps inventory is most useful with
// the recently-added apps on top — with an alphabetical (A–Z) option too.
enum AppSortOrder: String, CaseIterable, Identifiable {
    case installDate = "Install date"
    case name = "Name"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .installDate: return "calendar"
        case .name:        return "textformat"
        }
    }

    // Orders installed apps for this option. Install date is newest-first with
    // undated apps last; Name is a case-insensitive A–Z sort. Both tie-break on
    // name so the order is always stable.
    func sorted(_ apps: [InstalledApp]) -> [InstalledApp] {
        switch self {
        case .name:
            return apps.sorted {
                $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
        case .installDate:
            return apps.sorted { lhs, rhs in
                switch (lhs.installedDate, rhs.installedDate) {
                case let (l?, r?):
                    if l != r { return l > r }
                    return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
                case (_?, nil): return true   // dated before undated
                case (nil, _?): return false
                case (nil, nil):
                    return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
                }
            }
        }
    }
}

// A compact sort control matching the Homebrew Installed screen's PackageSortMenu,
// intended to sit just to the left of the toolbar search field. Offers the
// Install date / Name choice for the Mac Store / Other Apps lists.
struct AppSortMenu: View {
    @Binding var order: AppSortOrder

    var body: some View {
        Menu {
            Picker("Sort by", selection: $order) {
                ForEach(AppSortOrder.allCases) { opt in
                    Label(opt.rawValue, systemImage: opt.symbol).tag(opt)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort: \(order.rawValue)", systemImage: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort the list by install date (newest first) or by name (A–Z)")
    }
}

/// The "Mac Store/Other Apps" sidebar screen (and, with `updatesOnly`, its
/// Updates-only variant). Drives the whole non-Homebrew app surface: scanning,
/// the category segmented control (Installed page only), the per-app rows, and
/// the `mas`-missing prompt. The rows are awareness-only (Open App / Uninstall);
/// ForgedBrew doesn't update these apps. Reads its inventory from the shared
/// `AppUpdateService`.
struct AppUpdatesView: View {
    @Environment(AppDataService.self) private var appData
    @State private var service = AppUpdateService.shared
    // Toolbar search text, scoped to THIS page only: it filters the Mac App
    // Store / other-app lists in place (by app name / bundle id) instead of
    // triggering a global catalog search. Bound from the shared search field.
    var searchText: Binding<String> = .constant("")
    // When true, this screen shows ONLY apps with a pending update (the
    // "Mac Store/Other Apps Updates" sidebar row). The "All apps" section is
    // hidden so the page parallels the Homebrew Updates screen. When false
    // (the default, the "Mac Store/Other Apps" row) it shows both updates and
    // the full installed-app inventory.
    var updatesOnly: Bool = false

    // Normalized, lowercased query. Empty string means "no filter".
    private var searchQuery: String {
        searchText.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
    }
    private func matchesSearch(_ u: AppUpdate) -> Bool {
        guard !searchQuery.isEmpty else { return true }
        return u.appName.lowercased().contains(searchQuery)
            || u.bundleID.lowercased().contains(searchQuery)
    }
    private func matchesSearch(_ a: InstalledApp) -> Bool {
        guard !searchQuery.isEmpty else { return true }
        return a.appName.lowercased().contains(searchQuery)
            || a.bundleID.lowercased().contains(searchQuery)
    }
    // Which category the segmented control is showing. Defaults to "All" so
    // the user sees every non-Homebrew app across both categories at once.
    @State private var category: AppCategoryFilter = .all
    // True while we're installing the `mas` CLI from the inline prompt.
    @State private var installingMas = false

    // List ordering for the Mac Store / Other Apps lists. Persisted so the
    // choice sticks across launches. Defaults to Install date (newest first)
    // per the user's request; the menu also offers Name (A–Z). Mirrors the
    // Homebrew Installed screen's persisted sort.
    @AppStorage("forgedbrewMacAppsSortOrder") private var appSortOrderRaw: String = AppSortOrder.installDate.rawValue
    private var appSortOrder: Binding<AppSortOrder> {
        Binding(
            get: { AppSortOrder(rawValue: appSortOrderRaw) ?? .installDate },
            set: { appSortOrderRaw = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                // The "install mas" prompt lives at the TOP, right under the
                // header, so it's visible without scrolling past a long app
                // list. Only shown when the `mas` CLI is missing.
                masNote

                if service.isScanning {
                    scanningState
                } else {
                    // Segmented control picks the category on the Installed
                    // "Mac Store/Other Apps" page, where it's a useful filter over
                    // the full inventory. The Updates page is awareness-only and
                    // just shows every pending app update, so it omits the toggle
                    // (category stays .all).
                    if !updatesOnly {
                        Picker("Category", selection: $category) {
                            ForEach(AppCategoryFilter.allCases) { cat in
                                Text(cat.title).tag(cat)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360, alignment: .leading)
                    }

                    categorySections
                }
            }
            .padding(20)
        }
        .task {
            // First-appearance load only. The launch-time refresh
            // (refreshEverything) populates this list up front; navigating
            // into the page afterwards reuses that data instead of re-scanning
            // every click. The Rescan button and post-action rescans refresh it.
            if !service.hasScannedOnce && !appData.isRefreshingEverything {
                await rescan()
            }
        }
        // Admin-password prompt for the operations here that can need root —
        // e.g. Adopt (brew install of a matching cask). Mirrors the Homebrew
        // screens so the brew child can authenticate non-interactively via the
        // SUDO_ASKPASS helper once the user supplies the session password.
        // Sort control lives in the window toolbar, immediately to the LEFT
        // of the shared search field (SwiftUI renders .searchable last/right),
        // mirroring the Homebrew Installed screen. Only shown on the Installed
        // "Mac Store/Other Apps" page (not the Updates-only page, which keeps
        // its existing layout). Sorts the All apps list by Install date / Name.
        .toolbar {
            if !updatesOnly {
                ToolbarItem(placement: .primaryAction) {
                    AppSortMenu(order: appSortOrder)
                }
            }
        }
        .sheet(item: sudoRequestBinding) { request in
            SudoPasswordSheet(
                request: request,
                validate: { await appData.validateSudoPassword($0) }
            ) { password in
                appData.provideSudoPassword(password, for: request)
            }
        }
    }

    // Binds the shared pending sudo request for .sheet(item:). Setting it to nil
    // (sheet dismissed) cancels the request so the queued op is released.
    private var sudoRequestBinding: Binding<SudoRequest?> {
        Binding(
            get: { appData.pendingSudoRequest },
            set: { newValue in
                if newValue == nil, let current = appData.pendingSudoRequest {
                    appData.provideSudoPassword(nil, for: current)
                }
            }
        )
    }

    // The two stacked sections for the selected category: "Updates available"
    // (apps with a newer version) on top, "All apps" (the full installed list)
    // below — mirroring the Homebrew Updates screen.
    @ViewBuilder
    private var categorySections: some View {
        let updates = service.visibleUpdates(filter: category).filter(matchesSearch)
        // The Installed page lists every non-Homebrew app inline (a leftover
        // parked app just carries its "Parked" badge). App-level parking is no
        // longer offered from these screens — any historical app parks live on
        // the shared Parked sidebar screen — so there's nothing to exclude here.
        let apps = appSortOrder.wrappedValue.sorted(
            service.installedApps(filter: category)
                .filter(matchesSearch)
        )

        // Resolve each update's matching installed app (for its size + install
        // date) once, via a single bundle-id map, then hand the result to each
        // row. Previously every AppUpdateRow linear-scanned service.allApps
        // twice per body, making the section O(rows × inventory); this is O(1)
        // per row after one O(inventory) build.
        let appsByBundleID = Dictionary(
            service.allApps.map { ($0.bundleID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Updates available
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Updates available", count: updates.count)
            if updates.isEmpty {
                Text(updatesOnly
                     ? "No app updates available."
                     : "No updates available in this category.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(updates) { update in
                        AppUpdateRow(
                            update: update,
                            service: service,
                            inventoryApp: appsByBundleID[update.bundleID],
                            onUninstalled: { Task { await rescan() } }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // All apps — hidden in updates-only mode so that screen shows only
        // apps with a pending update (parallels the Homebrew Updates screen).
        if !updatesOnly {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("All apps", count: apps.count)
                if apps.isEmpty {
                    Text("No installed apps found in this category.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(apps) { app in
                            InstalledAppRow(app: app, service: service, onUninstalled: { Task { await rescan() } })
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    // A section title with a count pill (e.g. "Updates available  3").
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
    }

    // Excludes Homebrew-managed app bundles, then scans everything else.
    private func rescan() async {
        let managed = (try? await appData.cli.installedCaskAppBundles()) ?? []
        let managedPaths = Set(managed.map {
            URL(fileURLWithPath: $0.appPath).resolvingSymlinksInPath().path
        })
        await service.scan(managedAppPaths: managedPaths, casks: appData.casks)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                // Title row: rescan sits just to the right of the page name.
                HStack(spacing: 12) {
                    PageTitleLabel(title: updatesOnly ? "Mac Store/Other Apps Updates" : "Mac Store/Other Apps")
                    PageRefreshButton("Re-scan", isWorking: service.isScanning) {
                        Task { await rescan() }
                    }
                    .help("Re-check non-Homebrew apps for available updates")
                    Spacer()
                }
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text(updatesOnly
                 ? "These apps have a newer version available, but they update themselves — not through Homebrew. To update one, open the app and use its built-in updater (usually in its settings), or for a Mac App Store app, open the App Store and update it there. ForgedBrew lists them here so you know an update exists. Homebrew-managed packages are handled on the Homebrew Updates screen."
                 : "Apps installed outside Homebrew — Mac App Store apps and direct downloads. These update themselves, so ForgedBrew shows them for awareness: open an app to update it from its own settings, or update a Mac App Store app in the App Store. Homebrew-managed packages are handled on the Homebrew Updates screen.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var subtitle: String {
        if service.isScanning { return "Scanning…" }
        let n = service.visibleUpdates().count
        return n == 1 ? "1 app update available" : "\(n) app updates available"
    }

    // MARK: States

    private var scanningState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Checking apps for updates…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    // "All up to date" card for when the scan finds no pending app updates.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("All non-Homebrew apps are up to date", systemImage: "checkmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Text("ForgedBrew didn't find updates for any App Store or direct-download apps. Run Re-scan to check again.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // An informational note when the `mas` CLI isn't installed, explaining why
    // App Store apps may not show a target version.
    @ViewBuilder
    private var masNote: some View {
        if !service.masAvailable {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install the `mas` CLI to detect Mac App Store update versions here. Without it, App Store apps still open in the App Store for updating, but ForgedBrew can't read their available version — and your Mac App Store apps may not appear in the lists above.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        installMas()
                    } label: {
                        HStack(spacing: 6) {
                            if installingMas {
                                ProgressView().controlSize(.small)
                                Text("Installing mas\u{2026}")
                            } else {
                                Image(systemName: "arrow.down.circle")
                                Text("Install mas")
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .controlSize(.small)
                    .disabled(installingMas)
                    .help("Runs `brew install mas` so ForgedBrew can read Mac App Store update versions")
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // Installs the `mas` CLI via Homebrew, then re-scans so Mac App Store apps
    // and their versions show up.
    private func installMas() {
        guard !installingMas else { return }
        installingMas = true
        Task {
            for await _ in appData.installFormula("mas") {}
            await rescan()
            installingMas = false
        }
    }

}

// MARK: - Update row

/// One app row in the "Updates available" list. Shows icon, name, source badge,
/// version delta, and the per-app actions (Open App, Uninstall — awareness-only,
/// since ForgedBrew doesn't update these apps). Receives its matching inventory
/// app (for size + date) pre-resolved by the parent.
private struct AppUpdateRow: View {
    let update: AppUpdate
    let service: AppUpdateService
    // The matching installed app from the service's full inventory (AppUpdate
    // itself carries neither size nor install date), resolved ONCE by the parent
    // via a bundle-id map and passed in — so the row never linear-scans
    // service.allApps. nil when no match was found.
    var inventoryApp: InstalledApp? = nil
    // Called after a successful uninstall so the parent rescans the list.
    let onUninstalled: () -> Void
    @Environment(AppDataService.self) private var appData

    // App icon, resolved OFF the main thread (AppIconService.resolvedIcon(path:))
    // and held in @State so a fast scroll re-evaluating `body` never re-runs the
    // synchronous NSWorkspace.icon(forFile:) lookup that froze the UI.
    @State private var localIcon: NSImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            appIcon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(update.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    sourceBadge
                    // Adopt sits right next to the name so the primary action for
                    // an unmanaged app reads as part of its identity.
                    if update.isAdoptable {
                        AdoptNavButton(
                            bundleID: update.bundleID,
                            appName: update.appName,
                            suggestedToken: update.suggestedToken
                        )
                    }
                }
                versionLine
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let progress = appData.appUpdateProgress[update.bundleID] {
                    // Live in-place update HUD for THIS app — mirrors the
                    // Homebrew Updates row (spinner/checkmark + phase label).
                    updateProgressHUD(progress)
                } else {
                    HStack(spacing: 8) {
                        // Open App: launch the app so the user can update it from
                        // its own built-in updater (or, for a Mac App Store app,
                        // the App Store). ForgedBrew can't update these in place —
                        // this list is awareness that an update exists.
                        Button {
                            service.openApp(for: update)
                        } label: {
                            Text("Open App")
                        }
                        .buttonStyle(PillActionButtonStyle(tint: Color.accentColor))
                        .help("Open \(update.appName) so you can update it from within the app itself")

                        UninstallAppButton(
                            appPath: update.appPath,
                            appName: update.appName,
                            bundleID: update.bundleID,
                            service: service,
                            onUninstalled: onUninstalled
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var appIcon: some View {
        Group {
            if let localIcon {
                Image(nsImage: localIcon)
                    .resizable()
                    .frame(width: 36, height: 36)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "app").foregroundStyle(.secondary))
            }
        }
        // Cache-only peek on appear (instant for already-seen rows), then a
        // one-time off-main resolve so scrolling stays smooth.
        .onAppear {
            if localIcon == nil, let cached = AppIconService.shared.cachedIcon(path: update.appPath) {
                localIcon = cached
            }
        }
        .task(id: update.appPath) {
            if localIcon == nil {
                let resolved = await AppIconService.shared.resolvedIcon(path: update.appPath)
                if !Task.isCancelled, let resolved { localIcon = resolved }
            }
        }
    }

    private var sourceBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: update.source.symbol)
                .font(.system(size: 9))
            Text(update.source.displayName)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var versionLine: some View {
        // Version line — own row, styled 1:1 with the Homebrew Installed/Updates
        // screens (size 12 semibold; orange "v… → v…" when an update is available).
        HStack(spacing: 6) {
            if let available = update.availableVersion {
                Text("\(update.installedVersion.isEmpty ? "?" : update.installedVersion) → \(available)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Text(update.installedVersion.isEmpty ? "installed" : "v\(update.installedVersion)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        // Size + date metadata row — matched 1:1 to the Homebrew Installed screen
        // (own line, internaldrive + calendar pills, .titleAndIcon).
        HStack(spacing: 10) {
            if let size = rowSizeDisplay {
                Label(size, systemImage: "internaldrive")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let date = rowDateDisplay {
                Label("Installed \(date)", systemImage: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .labelStyle(.titleAndIcon)
    }

    // The on-disk size for this app, sourced from the service's full inventory
    // (AppUpdate itself carries no size). nil when unmeasured.
    private var rowSizeDisplay: String? {
        inventoryApp?.sizeDisplay
    }

    // The install date for this app, sourced from the service's full inventory.
    // nil when unknown.
    private var rowDateDisplay: String? {
        inventoryApp?.dateDisplay
    }

    // Live HUD for an in-place update of THIS app, styled to match the Homebrew
    // Updates row: a status icon + phase label, with a thin animated bar while
    // the work is active. Settles on a green check (Done) or a red warning.
    @ViewBuilder
    private func updateProgressHUD(_ progress: InstallProgress) -> some View {
        AppOperationHUD(progress: progress, appStoreUpdate: update, service: service)
    }

}

// MARK: - Installed app row (full list)
//
// A compact row for the "All apps" list: app icon, name, installed version,
// and either an Update button (when the scanner found a newer version) or an
// "Up to date" status. Clicking the name reveals the app in Finder.
private struct InstalledAppRow: View {
    let app: InstalledApp
    let service: AppUpdateService
    // Called after a successful uninstall so the parent rescans the list.
    let onUninstalled: () -> Void
    @Environment(AppDataService.self) private var appData

    // App icon resolved off the main thread, held in @State (see AppUpdateRow).
    @State private var localIcon: NSImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            appIcon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(app.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    // Adopt sits right next to the name so the primary action for
                    // an unmanaged app reads as part of its identity.
                    if app.isAdoptable {
                        AdoptNavButton(
                            bundleID: app.bundleID,
                            appName: app.appName,
                            suggestedToken: app.suggestedToken
                        )
                    }
                }
                versionLine
            }

            Spacer()

            // While an Adopt / Uninstall is in flight on this app, show the
            // shared flowing progress bar (green for adopt, red for uninstall)
            // in place of the action buttons \u2014 consistent with every other
            // row in the app and clearly labelled with what it's doing.
            if let progress = appData.appUpdateProgress[app.bundleID] {
                AppOperationHUD(progress: progress)
            } else {
            // Action set: Open App + Uninstall (plus Adopt next to the name when
            // a cask matches). These apps update themselves, so ForgedBrew only
            // surfaces awareness of an update — Open App is the honest path.
            HStack(spacing: 8) {
                // "Up to date" stays as a quiet status hint when there's no
                // pending update, so the row still reads as current at a glance.
                if app.update == nil && !service.isParked(app.bundleID) {
                    Label("Up to date", systemImage: "checkmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }

                // Open App — launch the app so the user can use its own updater.
                Button {
                    service.openApp(atPath: app.appPath)
                } label: {
                    Text("Open App")
                }
                .buttonStyle(PillActionButtonStyle(tint: Color.accentColor))
                .help("Open \(app.appName) so you can update it from within the app itself")

                UninstallAppButton(
                    appPath: app.appPath,
                    appName: app.appName,
                    bundleID: app.bundleID,
                    service: service,
                    onUninstalled: onUninstalled
                )
            }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.appPath)])
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        Group {
            if let localIcon {
                Image(nsImage: localIcon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "app").font(.system(size: 12)).foregroundStyle(.secondary))
            }
        }
        .onAppear {
            if localIcon == nil, let cached = AppIconService.shared.cachedIcon(path: app.appPath) {
                localIcon = cached
            }
        }
        .task(id: app.appPath) {
            if localIcon == nil {
                let resolved = await AppIconService.shared.resolvedIcon(path: app.appPath)
                if !Task.isCancelled, let resolved { localIcon = resolved }
            }
        }
    }

    @ViewBuilder
    private var versionLine: some View {
        // Version line — own row, styled 1:1 with the Homebrew Installed/Updates
        // screens (size 12 semibold; orange "old → new" when an update is available).
        HStack(spacing: 6) {
            // A parked app reads as Parked here, not as "update available":
            // suppress the orange "old → new" arrow even if a newer version
            // exists, and just show the current installed version.
            if !service.isParked(app.bundleID), let update = app.update, let available = update.availableVersion {
                Text("\(app.installedVersion.isEmpty ? "?" : app.installedVersion) → \(available)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Text(app.installedVersion.isEmpty ? "Version unknown" : "v\(app.installedVersion)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if service.isParked(app.bundleID) {
                Label("Parked", systemImage: "parkingsign.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
        // Size + date metadata row — matched 1:1 to the Homebrew Installed screen
        // (own line, internaldrive + calendar pills, .titleAndIcon).
        HStack(spacing: 10) {
            if let size = app.sizeDisplay {
                Label(size, systemImage: "internaldrive")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let date = app.dateDisplay {
                Label("Installed \(date)", systemImage: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Parked app-update row

// Internal (not private) so the unified Parked sidebar screen can reuse this
// row to show parked Mac App Store / Other apps alongside parked Homebrew packages.
struct ParkedAppUpdateRow: View {
    let record: ParkedAppUpdate
    let service: AppUpdateService

    // Shared, configured once — avoids rebuilding a DateFormatter in the row body
    // on every render.
    private static let expiryFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.parkType.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.appName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(parkDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Change-hold control.
            Menu {
                Button("Indefinitely") { service.changePark(bundleID: record.bundleID, parkType: .indefinite) }
                Button("Until next version") { service.changePark(bundleID: record.bundleID, parkType: .untilNextVersion) }
                Menu("For a set time") {
                    Button("1 day")   { service.changePark(bundleID: record.bundleID, parkType: .duration, duration: .oneDay) }
                    Button("1 week")  { service.changePark(bundleID: record.bundleID, parkType: .duration, duration: .oneWeek) }
                    Button("1 month") { service.changePark(bundleID: record.bundleID, parkType: .duration, duration: .oneMonth) }
                }
            } label: {
                Text("Change hold")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Change how long this app update stays parked")

            Button("Unpark") { service.unpark(record.bundleID) }
                .help("Stop holding this update — it returns to the App Updates list")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var parkDescription: String {
        switch record.parkType {
        case .indefinite:
            return "Held indefinitely"
        case .untilNextVersion:
            if let v = record.parkedVersion { return "Held until a version newer than \(v) ships" }
            return "Held until the next version ships"
        case .duration:
            if let expires = record.expiresAt {
                return "Held until \(Self.expiryFormatter.string(from: expires))"
            }
            return "Held for a set time"
        }
    }
}


// MARK: - Uninstall button (non-Homebrew apps)
//
// A trailing trash button shown on both the "Updates available" rows and the
// full "Mac Store/Other Apps" list. Mirrors the Homebrew Installed screen's
// Uninstall control (red capsule, trash icon, fills on hover) and the same
// "Uninstall X?" destructive confirmation — but because these apps aren't
// package-managed, Uninstall here moves the .app to the Trash (recoverable)
// rather than running a brew --zap. On success it asks the caller to rescan
// so the list refreshes.
// MARK: - Adopt button (Other Apps list + Updates section)
//
// Hands a manually-installed app to Homebrew so it can be updated/removed like
// any other cask. Shown only when a matching cask exists (the row's
// isAdoptable). Mirrors UninstallAppButton's capsule styling so the two
// surfaces (Installed list + Updates section) stay visually consistent.
// Shared per-app operation HUD for the Mac App / Other Apps rows. Renders the
// status line plus the bright-green (red for uninstall) flowing dash bar used
// across the Homebrew screens, so Adopt / Uninstall / Update all look the same
// and clearly label what they're doing ("Adopting…", "Uninstalling…",
// "Updating…"). On a failed App Store update it also surfaces an Open App Store
// button so the user is never left at a dead end.
private struct AppOperationHUD: View {
    let progress: InstallProgress
    // Optional escape hatch for a failed App Store update.
    var appStoreUpdate: AppUpdate? = nil
    var service: AppUpdateService? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: progress.statusSymbol)
                    .foregroundStyle(tint)
                    .opacity(progress.isActive ? 0 : 1)
                    .frame(width: progress.isActive ? 0 : nil)
                Text(progress.statusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            if progress.isActive {
                GreenDashProgressBar(
                    tint: progress.isUninstall
                        ? .red
                        : Color(red: 0.16, green: 0.86, blue: 0.30)
                )
                .frame(width: 160, height: 4)
            } else if case .failed(let message) = progress.phase {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 340, alignment: .leading)
                if let update = appStoreUpdate, update.source == .appStore, let service {
                    Button {
                        service.openUpdate(for: update)
                    } label: {
                        Label("Open App Store", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(PillActionButtonStyle(tint: ActionColors.update))
                    .help("Open \(update.appName) in the App Store to finish updating")
                }
            }
        }
    }

    private var tint: Color {
        switch progress.phase {
        case .finished: return .green
        case .failed:   return .red
        default:        return .secondary
        }
    }
}

// Adopt button shown next to a Mac App / Other Apps row name. Instead of
// adopting in place (which surfaced an orphaned "see conditions above" error
// with no surrounding context on these rows), it routes the user to the Adopt
// flow in Maintenance — the screen that owns the full explanation and clear
// per-app error messaging. Styled brownie-grey so it stands out as the primary
// action for an unmanaged app without competing with the trailing pill buttons.
private struct AdoptNavButton: View {
    let bundleID: String
    let appName: String
    let suggestedToken: String?
    @Environment(AppDataService.self) private var appData

    @State private var isHovering = false

    var body: some View {
        Button {
            // Raise a fresh request every tap so repeated taps still fire the
            // observers in DetailRouter (switch to Maintenance) and
            // MaintenanceView (open the Adopt sheet, scan, target this app).
            appData.adoptNavigationRequest = AdoptNavigationRequest(
                bundleID: bundleID,
                appName: appName,
                suggestedToken: suggestedToken
            )
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 11, weight: .semibold))
                Text("Adopt")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(ActionColors.adoptText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isHovering
                    ? AnyShapeStyle(ActionColors.adopt)
                    : AnyShapeStyle(ActionColors.adopt.opacity(0.9)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Adopt \(appName) into Homebrew \u{2014} opens the Adopt screen in Maintenance, where you can review the match and adopt it so ForgedBrew can update and remove it like any other cask.")
    }
}

/// Trailing trash button for a non-Homebrew app. Confirms, captures the session
/// admin password (for apps in protected locations), then moves the .app to the
/// Trash via the service — driving the shared red HUD and asking the parent to
/// rescan on success. (See the section comment above for the fuller rationale.)
private struct UninstallAppButton: View {
    let appPath: String
    let appName: String
    let bundleID: String
    let service: AppUpdateService
    // Called after a successful move-to-Trash so the parent can rescan.
    let onUninstalled: () -> Void
    @Environment(AppDataService.self) private var appData

    @State private var isHovering = false
    @State private var showConfirm = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        Button {
            showConfirm = true
        } label: {
            Label("Uninstall", systemImage: "trash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? Color.white : Color.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isHovering
                        ? AnyShapeStyle(Color.red)
                        : AnyShapeStyle(Color.red.opacity(0.12)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Move \(appName) to the Trash (recoverable). Leftover support files are not removed.")
        .alert("Uninstall \(appName)?", isPresented: $showConfirm) {
            Button("Uninstall", role: .destructive) {
                Task {
                    // Capture the session admin password up-front — exactly like
                    // a Homebrew uninstall — so apps in protected locations can
                    // be removed with elevated rights instead of erroring out.
                    // Cancelling the password prompt aborts the uninstall.
                    guard let password = await appData.ensureSessionSudoPassword(
                        verb: "uninstall", subject: appName
                    ) else { return }
                    // Drive the shared per-app HUD (red flowing bar) for the
                    // duration of the uninstall, consistent with Adopt/Update.
                    appData.appUpdateProgress[bundleID] = InstallProgress(
                        phase: .uninstalling, log: [], isUninstall: true, verb: "Uninstalling"
                    )
                    if let message = await service.uninstall(
                        appPath: appPath, bundleID: bundleID, sudoPassword: password
                    ) {
                        appData.appUpdateProgress[bundleID]?.phase = .failed(message)
                        errorMessage = message
                        showError = true
                    } else {
                        // Briefly show the success state, then let the parent
                        // rescan (the row leaves the list either way).
                        appData.appUpdateProgress[bundleID]?.phase = .finished
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        appData.appUpdateProgress[bundleID] = nil
                        onUninstalled()
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(appName) will be moved to the Trash. You can restore it from the Trash until it's emptied. Any leftover support files in your Library are not removed.")
        }
        .alert("Couldn't uninstall \(appName)", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
}
