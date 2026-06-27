import SwiftUI

// MARK: - InstalledView (file overview)
//
// The "Installed Homebrew Apps and Formulae" screen. Lists every package brew
// reports as installed, split into two sorted sections — "Updates Available" and
// "Up to Date" — with per-row Update / Park / Uninstall actions wired through the
// shared install manager on AppDataService (so operations survive navigation and
// auto-refresh installed state on finish). Three persisted filters narrow the
// list: type (casks / formulae / all), origin (all / installed by me /
// dependencies), and sort order (name / install date); a page-local search box
// filters in place. This file defines, top to bottom: the row view
// (InstalledRowView), the filter/sort enums (InstalledFilter, OriginFilter,
// PackageSortOrder), the shared sort control (PackageSortMenu), and finally the
// screen itself (InstalledView).

// MARK: - InstalledRowView

/// One installed-package row: icon, name, token + version (or "old → new" when
/// outdated), badges (parked / dependency), optional inline dependency list and
/// size/date metadata, a live progress line while an operation runs, and the
/// trailing Update / Park / Unpark / Uninstall actions. The row only *requests*
/// destructive/parking actions via its closures; the parent owns confirmation
/// and execution.
struct InstalledRowView: View {
    let package: InstalledPackage
    // The formula dependencies to show inline beneath the name row, supplied by
    // the parent from the formula catalog. Empty for casks (no dependency
    // concept) and for formulae we could not resolve in the catalog.
    var dependencies: [String] = []
    // True while THIS package has an uninstall (or any op) running on the shared
    // manager, so the row can show a spinner and disable its Uninstall button.
    let isBusy: Bool
    let onTap: (InstalledPackage) -> Void
    // Asks the parent to begin a deep (—zap) uninstall for this package. The
    // parent presents a confirmation first; the row only requests it.
    let onUninstall: (InstalledPackage) -> Void
    // Asks the parent to upgrade this package (only ever invoked for outdated
    // rows). Routes through the shared install manager so it survives
    // navigation and auto-refreshes installed state on finish.
    let onUpdate: (InstalledPackage) -> Void
    // Whether this package is currently parked (held out of Updates / Update
    // All). Drives a small badge and the Park-vs-Unpark context menu item.
    var isParked: Bool = false
    // Parks this package (hold its version, skip it in Update All). nil when the
    // host view doesn't offer parking.
    var onPark: ((InstalledPackage, ParkType, ParkDuration?) -> Void)? = nil
    // Unparks this package (return it to the normal Updates flow).
    var onUnpark: ((InstalledPackage) -> Void)? = nil
    // Live progress for THIS package's in-flight operation (download / install /
    // removing old / etc.), read from the shared install manager. nil when no
    // operation is running. Drives the per-app status line + phase icon the
    // user asked for so big, slow packages show what's happening, not just a
    // bare spinner.
    var progress: InstallProgress? = nil

    @State private var isHoveringUninstall = false
    @State private var isHoveringUpdate = false
    @State private var isHoveringPark = false
    // Drives the Park options dialog. A plain Button + confirmationDialog is used
    // instead of a borderless Menu because a Menu does not reliably show a hover
    // effect on macOS. The Button hovers exactly like the Update/Uninstall ones.
    @State private var showParkOptions = false
    @State private var showParkDurationOptions = false

    // "Installed Jun 1, 2026" / "Updated …" — the user asked to see install or
    // update date per app. We can't tell install-vs-update apart from brew's
    // single timestamp, so label it "Updated" for outdated/just-upgraded apps
    // and "Installed" otherwise. nil date → omit the pill entirely.
    // Shared, configured once — DateFormatter construction is expensive and this
    // runs in a row body for every visible row on every render.
    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt
    }()

    private var dateText: String? {
        guard let date = package.installedDate else { return nil }
        return Self.dateFormatter.string(from: date)
    }

    // Tint for the status icon + label: accent while in flight, green on
    // success, red on failure.
    private func statusTint(_ progress: InstallProgress) -> Color {
        switch progress.phase {
        // Uninstalls read red the whole way through (and on success), so
        // removing an app is visually distinct from installing/updating one
        // — matching the detail card's color coding.
        case .finished: return progress.isUninstall ? .red : .green
        case .failed:   return .red
        case .uninstalling: return .red
        default:        return progress.isUninstall ? .red : .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(token: package.token, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(Self.displayName(for: package.token))
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Text(package.token)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let info = package.outdatedInfo {
                        Text("v\(info.installedVersion) → v\(info.currentVersion)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                    } else {
                        Text("v\(package.installedVersion ?? "?")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if isParked {
                        Label("Parked", systemImage: "parkingsign.circle")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    // Dependency badge: a formula Homebrew pulled in only as a
                    // dependency of something else (not installed on request).
                    // Helps users tell their chosen tools apart from the noise.
                    if package.isDependencyOnly {
                        Label("Dependency", systemImage: "link")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                            .help(Text(verbatim: "Installed automatically as a dependency, not on request. Clear unused dependencies from Maintenance \u{25B8} Orphaned packages."))
                    }
                }
                // Inline dependency list. For formulae, show what this package
                // depends on right under the name and Dependency tag, so users
                // can see relationships without opening the detail card. Casks
                // have no dependency concept, and formulae we could not resolve
                // in the catalog simply show nothing.
                if !dependencies.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text("Depends on: " + dependencies.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(Text(verbatim: "Formulae this package requires to run."))
                }
                // Size + date metadata row (the new per-app detail the user
                // asked for). Each pill is omitted when its value is unknown.
                HStack(spacing: 10) {
                    if let size = package.sizeDisplay {
                        Label(size, systemImage: "internaldrive")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let dateText {
                        Label("\(package.isOutdated ? "Updated" : "Installed") \(dateText)",
                              systemImage: "calendar")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .labelStyle(.titleAndIcon)

                // Live per-app status while an operation is in flight (the new
                // status indicator). Shows the current phase (Downloading…,
                // Installing…, Removing old version…) with a matching icon and a
                // small inline spinner so large, slow packages clearly show
                // progress instead of an opaque wait. Success/failure linger a
                // few seconds (handled by the manager) before clearing.
                if let progress {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if progress.isActive {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            }
                            Image(systemName: progress.statusSymbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(statusTint(progress))
                            Text(progress.statusLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(statusTint(progress))
                            if case .failed(let message) = progress.phase {
                                Text(message)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(message)
                            }
                        }
                        // Bright-green flowing progress bar while the operation
                        // is in flight (install/upgrade/uninstall through their
                        // phases). Indeterminate by design; hidden on Done/Failed.
                        if progress.isActive {
                            GreenDashProgressBar(
                                tint: progress.isUninstall
                                    ? .red
                                    : Color(red: 0.16, green: 0.86, blue: 0.30)
                            )
                            .frame(height: 4)
                        }
                    }
                    .padding(.top, 1)
                }
            }

            Spacer()

            // Inline Update + Park buttons — shown only when this package is
            // outdated, not parked, and no operation is already running on it.
            // Mirrors the dedicated Updates screen so the user can upgrade (or
            // hold) right from the Installed list. While busy, the shared spinner
            // below stands in. Parked rows show an Unpark button instead.
            if package.isOutdated && !isParked && !isBusy {
                Button {
                    onUpdate(package)
                } label: {
                    Label("Update", systemImage: "arrow.up.circle")
                        .font(.system(size: 11, weight: .semibold))
                        // Uses the shared, desaturated amber instead of the
                        // bright system orange, and settles to a softer fill on
                        // hover so it no longer flares too bright.
                        .foregroundStyle(isHoveringUpdate ? Color.white : ActionColors.update)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            isHoveringUpdate
                                ? AnyShapeStyle(ActionColors.update.opacity(0.78))
                                : AnyShapeStyle(ActionColors.update.opacity(0.15)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringUpdate = $0 }
                .help("Update this package to the latest version now.")

                if onPark != nil {
                    parkButton
                }
            } else if isParked, let onUnpark {
                // Parked: a discoverable Unpark button (with a hover tooltip)
                // returns the package to the normal update flow.
                Button {
                    onUnpark(package)
                } label: {
                    Label("Unpark", systemImage: "play.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHoveringPark ? Color.white : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            isHoveringPark
                                ? AnyShapeStyle(Color.secondary)
                                : AnyShapeStyle(Color.secondary.opacity(0.12)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringPark = $0 }
                .help("Unpark this package: return it to the Updates list and Update All so it can be upgraded again.")
            }

            // Per-app Uninstall button. Only casks support `--cask --zap`, so
            // formulae are uninstalled too but without the zap (handled by the
            // parent based on package.type). Shows a spinner while in flight.
            if isBusy {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 80)
            } else {
                Button {
                    onUninstall(package)
                } label: {
                    Label("Uninstall", systemImage: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHoveringUninstall ? Color.white : Color.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            isHoveringUninstall
                                ? AnyShapeStyle(Color.red)
                                : AnyShapeStyle(Color.red.opacity(0.12)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringUninstall = $0 }
                .help("Uninstall and remove leftover support files")
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onTap(package) }
    }

    // Park button shown next to Update for outdated rows. It's a menu so the
    // user can choose how long to hold the package, but it reads and hovers like
    // a button. The .help tooltip explains what parking does on hover.
    // A plain Button (NOT a Menu) so it gets a reliable hover effect on macOS,
    // matching the Update / Uninstall / Unpark buttons. Tapping it opens a
    // confirmationDialog to choose how long to hold the package; the "For a set
    // time" choice opens a second dialog with the duration presets.
    @ViewBuilder
    private var parkButton: some View {
        if let onPark {
            Button {
                showParkOptions = true
            } label: {
                Label("Park", systemImage: "parkingsign.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHoveringPark ? Color.white : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        isHoveringPark
                            ? AnyShapeStyle(Color.secondary)
                            : AnyShapeStyle(Color.secondary.opacity(0.12)),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringPark = $0 }
            .animation(.easeOut(duration: 0.12), value: isHoveringPark)
            .help("Park this package: hold its current version and skip it in Update All until you unpark it (or it auto-resurfaces).")
            // Step 1: pick the park type.
            .confirmationDialog("Park \(InstalledRowView.displayName(for: package.token))",
                                isPresented: $showParkOptions,
                                titleVisibility: .visible) {
                Button(ParkType.indefinite.displayName) { onPark(package, .indefinite, nil) }
                Button(ParkType.untilNextVersion.displayName) { onPark(package, .untilNextVersion, nil) }
                Button(ParkType.duration.displayName) { showParkDurationOptions = true }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Hold this package at its current version and skip it in Update All until you unpark it.")
            }
            // Step 2: if the user chose "For a set time", pick the duration.
            .confirmationDialog("Park for how long?",
                                isPresented: $showParkDurationOptions,
                                titleVisibility: .visible) {
                ForEach(ParkDuration.allCases, id: \.self) { d in
                    Button(d.rawValue) { onPark(package, .duration, d) }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    // Turns a brew token like "google-chrome" into "Google Chrome" for display.
    static func displayName(for token: String) -> String {
        token
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - InstalledFilter

enum InstalledFilter: String, CaseIterable {
    // "All" is listed FIRST so it sits in the same position as the OriginFilter
    // segmented control below it (which also leads with "All"). Previously this
    // enum trailed with "All" while OriginFilter led with it, so the two
    // segmented controls put "All" on opposite ends — confusing side by side.
    case all = "All"
    case casks = "Casks"
    case formulae = "Formulae"
}

// MARK: - OriginFilter
//
// Splits installed packages by HOW they got here: everything, only the ones the
// user installed deliberately (top-level / "leaf"-style), or only the formulae
// Homebrew pulled in as dependencies of something else. Casks have no
// dependency concept in brew, so they always count as top-level and naturally
// drop out of the Dependencies view.
enum OriginFilter: String, CaseIterable {
    case all = "All"
    case topLevel = "Installed by me"
    case dependency = "Dependencies"

    // Does this package belong in the given origin bucket?
    func matches(_ pkg: InstalledPackage) -> Bool {
        switch self {
        case .all:        return true
        case .topLevel:   return pkg.installedOnRequest
        case .dependency: return pkg.isDependencyOnly
        }
    }
}

// MARK: - PackageSortOrder
//
// How the installed-package lists are ordered. Shared by the Installed screen
// and the lower (full installed) section of the Homebrew Updates screen.
// "Name" (alphabetical) is the default; "Install date" orders by brew's
// installed/updated timestamp, newest first, with undated packages last.
enum PackageSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case installDate = "Install date"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .name:        return "textformat"
        case .installDate: return "calendar"
        }
    }

    // Returns the packages ordered for this option. Name is a case-insensitive
    // sort on the display name; install date is newest-first, undated last,
    // tie-broken by name so the order is always stable.
    func sorted(_ packages: [InstalledPackage]) -> [InstalledPackage] {
        // Decorate-sort-undecorate: compute each package's display name ONCE
        // (the split/map/join in displayName allocates several strings) and sort
        // on the precomputed key. The previous form recomputed displayName twice
        // per comparison — O(N log N) string builds — on every render.
        switch self {
        case .name:
            return packages
                .map { (pkg: $0, key: InstalledRowView.displayName(for: $0.token)) }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map(\.pkg)
        case .installDate:
            return packages
                .map { (pkg: $0, date: $0.installedDate, key: InstalledRowView.displayName(for: $0.token)) }
                .sorted { lhs, rhs in
                    switch (lhs.date, rhs.date) {
                    case let (l?, r?):
                        if l != r { return l > r }
                        return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                    case (_?, nil): return true   // dated before undated
                    case (nil, _?): return false
                    case (nil, nil):
                        return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                    }
                }
                .map(\.pkg)
        }
    }
}

// A compact sort control (label + segmented-style menu) intended to sit just to
// the left of the toolbar search field. Reused by the Installed and Updates
// screens so both offer the identical Name / Install date choice.
struct PackageSortMenu: View {
    @Binding var order: PackageSortOrder

    var body: some View {
        Menu {
            Picker("Sort by", selection: $order) {
                ForEach(PackageSortOrder.allCases) { opt in
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
        .help("Sort the list by name (A–Z) or by install date (newest first)")
    }
}

// MARK: - InstalledView

struct InstalledView: View {
    @Environment(AppDataService.self) var appData
    // Type filter (casks / formulae / all). Persisted so the choice sticks
    // across launches AND survives drilling into a detail card and back (the
    // router recreates this view, which would otherwise reset plain @State).
    @AppStorage("forgedbrewInstalledTypeFilter") private var filterRaw: String = InstalledFilter.all.rawValue
    private var filter: Binding<InstalledFilter> {
        Binding(
            get: { InstalledFilter(rawValue: filterRaw) ?? .all },
            set: { filterRaw = $0.rawValue }
        )
    }
    // How packages got installed (all / installed by me / dependencies).
    // Persisted so the choice sticks across launches.
    @AppStorage("forgedbrewInstalledOriginFilter") private var originFilterRaw: String = OriginFilter.all.rawValue
    private var originFilter: Binding<OriginFilter> {
        Binding(
            get: { OriginFilter(rawValue: originFilterRaw) ?? .all },
            set: { originFilterRaw = $0.rawValue }
        )
    }
    // List ordering. Persisted so the user's choice sticks across launches.
    // Defaults to Name (alphabetical) as requested.
    @AppStorage("forgedbrewInstalledSortOrder") private var sortOrderRaw: String = PackageSortOrder.name.rawValue
    private var sortOrder: Binding<PackageSortOrder> {
        Binding(
            get: { PackageSortOrder(rawValue: sortOrderRaw) ?? .name },
            set: { sortOrderRaw = $0.rawValue }
        )
    }
    // The package the user tapped Uninstall on, awaiting confirmation. nil when
    // no confirmation is showing.
    @State private var pendingUninstall: InstalledPackage? = nil
    var onPackageTapped: ((InstalledPackage) -> Void)?
    // Toolbar search text, scoped to THIS page only: it filters the installed
    // list in place (by name / token) rather than triggering a global catalog
    // search. Bound from the shared search field by DetailRouter.
    var searchText: Binding<String> = .constant("")

    // Filtered packages based on the segmented type filter AND the page-local
    // search query. The search query is normalized ONCE here rather than being
    // re-trimmed/re-lowercased for every package (which the old per-element
    // matchesSearch did on every render).
    private var filtered: [InstalledPackage] {
        let byType: [InstalledPackage]
        switch filter.wrappedValue {
        case .casks:
            byType = appData.installedPackages.filter { $0.type == .cask }
        case .formulae:
            byType = appData.installedPackages.filter { $0.type == .formula }
        case .all:
            byType = appData.installedPackages
        }
        let byOrigin = byType.filter { originFilter.wrappedValue.matches($0) }
        let q = searchText.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return byOrigin }
        return byOrigin.filter { pkg in
            InstalledRowView.displayName(for: pkg.token).lowercased().contains(q)
                || pkg.token.lowercased().contains(q)
        }
    }

    // Total installed counts by type, used for the at-a-glance breakdown line
    // under the header (independent of the current segmented filter).
    private var caskCount: Int {
        appData.installedPackages.filter { $0.type == .cask }.count
    }
    private var formulaCount: Int {
        appData.installedPackages.filter { $0.type == .formula }.count
    }

    // Dependencies for an installed package, resolved from the formula catalog.
    // Casks have no dependency concept, so they always return empty. Formulae
    // not found in the catalog (e.g. deprecated/disabled and not browsable)
    // also return empty, so the row simply omits the inline line.
    private func dependencies(for pkg: InstalledPackage) -> [String] {
        guard pkg.type == .formula else { return [] }
        return appData.formulae.first { $0.name == pkg.token }?.dependencies ?? []
    }

    // "Updates Available" excludes parked packages — they're held out of the
    // update flow and shown (with a Parked badge) in the bottom section instead.
    // Both sections honor the selected sort order (Name / Install date).
    private var outdated: [InstalledPackage] {
        sortOrder.wrappedValue.sorted(filtered.filter { $0.isOutdated && !appData.isParked($0) })
    }

    // Everything not offered for update: genuinely up-to-date packages plus any
    // parked packages (even if a newer version exists, they're intentionally
    // held here rather than in Updates Available).
    private var upToDate: [InstalledPackage] {
        sortOrder.wrappedValue.sorted(filtered.filter { !$0.isOutdated || appData.isParked($0) })
    }

    var body: some View {
        // Evaluate the two sorted sections ONCE per render. Each was a computed
        // property that re-ran the full multi-pass filter + sort on every
        // access, and the List below reads each one three times (the guard, the
        // ForEach, and the header count) — so this collapses six full
        // filter+sort passes per render down to two. Same-name locals shadow the
        // computed properties so the references below are unchanged.
        let outdated = self.outdated
        let upToDate = self.upToDate
        return VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                // Title row: refresh sits just to the right of the page name
                // (manual refresh re-runs the brew CLI to re-read installed
                // packages, mirroring the brew doctor "Re-run" affordance).
                HStack(spacing: 12) {
                    PageTitleLabel(title: "Installed Homebrew Apps")
                    PageRefreshButton("Re-scan", isWorking: appData.isLoadingInstalled) {
                        Task { await appData.refreshInstalled() }
                    }
                    Spacer()
                }
                Text("\(appData.installedPackages.count) packages")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                // Breakdown reminder: how many are apps (casks) vs CLI tools
                // (formulae). Pluralized so it reads naturally at any count.
                Text("\(caskCount) app\(caskCount == 1 ? "" : "s") and \(formulaCount) formula\(formulaCount == 1 ? "" : "e") installed")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Segmented filter (type: casks / formulae / all)
            Picker("", selection: filter) {
                ForEach(InstalledFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            // Origin filter (all / installed by me / dependencies). Lets users
            // see just the packages they chose to install, hiding the
            // dependency noise — Homebrew's "leaves" idea, made friendly.
            Picker("", selection: originFilter) {
                ForEach(OriginFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 4)

            // One-line explainer for the dependency view, since "Dependencies"
            // is formulae-only (casks have no dependency concept in brew).
            if originFilter.wrappedValue == .dependency {
                Text("Formulae Homebrew installed only as dependencies. Removing one its parents still need can break them \u{2014} clear unused ones safely from Maintenance \u{25B8} Orphaned packages.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()

            // List
            List {
                if !outdated.isEmpty {
                    Section {
                        ForEach(outdated) { pkg in
                            InstalledRowView(
                                package: pkg,
                                dependencies: pkg.dependencies,
                                isBusy: appData.isOperationInFlight(token: pkg.token),
                                onTap: { onPackageTapped?($0) },
                                onUninstall: { pendingUninstall = $0 },
                                onUpdate: { startUpdate($0) },
                                isParked: appData.isParked(pkg),
                                onPark: { p, type, duration in
                                    Task { await appData.park(package: p, parkType: type, duration: duration) }
                                },
                                onUnpark: { p in
                                    Task { await appData.unpark(token: p.token, type: p.type) }
                                },
                                progress: appData.installProgress[pkg.token]
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("Updates Available (\(outdated.count))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }
                }

                if !upToDate.isEmpty {
                    Section {
                        ForEach(upToDate) { pkg in
                            InstalledRowView(
                                package: pkg,
                                dependencies: pkg.dependencies,
                                isBusy: appData.isOperationInFlight(token: pkg.token),
                                onTap: { onPackageTapped?($0) },
                                onUninstall: { pendingUninstall = $0 },
                                onUpdate: { startUpdate($0) },
                                isParked: appData.isParked(pkg),
                                onPark: { p, type, duration in
                                    Task { await appData.park(package: p, parkType: type, duration: duration) }
                                },
                                onUnpark: { p in
                                    Task { await appData.unpark(token: p.token, type: p.type) }
                                },
                                progress: appData.installProgress[pkg.token]
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("Up to Date (\(upToDate.count))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 0, idealHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)
        }
        // Claim all available space so the scrolling List — not the window —
        // absorbs any content-height changes. Without this, toggling the
        // Dependencies filter adds an explainer line and the VStacks ideal
        // height grows, which SwiftUI tried to satisfy by making the window
        // taller (pushing it off the bottom of the screen).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .task {
            // Only load on the FIRST appearance this session (before the
            // launch-time refreshEverything() has landed). After that, the
            // list stays populated from the shared inventory; navigating in
            // and out no longer forces a brew re-read on every click. The
            // page's Refresh button (and post-install/uninstall/park
            // auto-refreshes) are how the list updates from here on.
            if !appData.hasLoadedInstalledOnce && !appData.isRefreshingEverything {
                await appData.refreshInstalled()
            }
        }
        // Admin-password prompt for privileged casks (those that install via a
        // `pkg`, e.g. Microsoft Office). Raised by the shared install manager
        // when an operation needs root; on submit we hand the password back so
        // the queued operation resumes via the SUDO_ASKPASS helper.
        .sheet(item: sudoRequestBinding) { request in
            SudoPasswordSheet(
                request: request,
                validate: { await appData.validateSudoPassword($0) }
            ) { password in
                appData.provideSudoPassword(password, for: request)
            }
        }
        // Confirm before a destructive uninstall. Casks use the deep —zap
        // (removes leftover support/config files); formulae just uninstall.
        .alert(
            "Uninstall \(pendingUninstall.map { InstalledRowView.displayName(for: $0.token) } ?? "")?",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            presenting: pendingUninstall
        ) { pkg in
            Button("Uninstall", role: .destructive) {
                // Gate on the session password first (prompt once per session,
                // reuse after, cancel aborts), then route through the shared
                // manager so the operation survives navigation and refreshes
                // installed state on finish.
                let target = pkg
                pendingUninstall = nil
                Task {
                    guard let password = await appData.ensureSessionSudoPassword(
                        verb: "uninstall", subject: "your apps"
                    ) else { return }
                    if target.type == .cask {
                        // Deep clean: remove the app AND its leftover files.
                        appData.startUninstall(token: target.token, zap: true, sudoPassword: password)
                    } else {
                        appData.startUninstall(token: target.token, isFormula: true, sudoPassword: password)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingUninstall = nil }
        } message: { pkg in
            Text(pkg.type == .cask
                 ? "This removes the app and its leftover support and configuration files."
                 : "This removes the formula and its installed files.")
        }
        // Sort control lives in the window toolbar, immediately to the LEFT of
        // the shared search field (SwiftUI always renders .searchable last/right),
        // so it sits beside the search bar rather than below it in the page
        // header. Sorts both sections by Name or Install date.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PackageSortMenu(order: sortOrder)
            }
        }
    }

    // Binding over the shared install manager's outstanding sudo request, so the
    // password sheet presents via `.sheet(item:)`. Setting it to nil (sheet
    // dismiss) is treated as a cancel and clears the queued operation.
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

    // Upgrades a single package via the shared install manager. Its completion
    // runs refreshInstalled(), flipping isOutdated → false so the row drops out
    // of the "Updates Available" section and reappears under "Up to Date".
    // Gate on the session password first (prompt once per session, reuse after,
    // cancel aborts), then upgrade the single package.
    private func startUpdate(_ pkg: InstalledPackage) {
        Task {
            guard let password = await appData.ensureSessionSudoPassword() else { return }
            appData.startInstall(
                token: pkg.token,
                isUpgrade: true,
                isFormula: pkg.type == .formula,
                sudoPassword: password
            )
        }
    }
}
