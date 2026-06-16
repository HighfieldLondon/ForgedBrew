import SwiftUI

// MARK: - UpdateRowView
//
// One row in the Updates screen. Mirrors the visual language of
// InstalledRowView (app icon, display name, token, version delta) but is
// tailored to the update flow:
//  • In the "Updates Available" section the row carries a leading checkbox for
//    multi-select and a per-row "Update" button.
//  • In the "Up to Date" section it shows a calm green check and the current
//    version, with no checkbox or action.
// All upgrades route through the shared install manager
// (appData.startInstall(token:isUpgrade:true:isFormula:)) so they survive
// navigation, run brew cleanup, and refresh installed state on finish — which
// is what makes a just-updated item drop out of the top list and reappear in
// the bottom one automatically.
struct UpdateRowView: View {
    let package: InstalledPackage
    // Whether this row sits in the selectable "Updates Available" section.
    let isSelectable: Bool
    // Multi-select state (only meaningful when isSelectable).
    let isSelected: Bool
    // True while THIS package has an operation running on the shared manager,
    // so the row can show a spinner and disable its Update button.
    let isBusy: Bool
    // Non-nil when the most recent upgrade attempt for this package failed.
    // Carries the user-facing error message (e.g. brew permission/lock error).
    let failureMessage: String?
    let onToggleSelect: (InstalledPackage) -> Void
    let onUpdate: (InstalledPackage) -> Void
    let onTap: (InstalledPackage) -> Void
    // Parks this package: hold its version and skip it in Update All. The chosen
    // park type/duration determines when it auto-resurfaces. Optional so non-
    // selectable (up-to-date) rows can omit it.
    var onPark: ((InstalledPackage, ParkType, ParkDuration?) -> Void)? = nil
    // Live progress for THIS package's in-flight upgrade, read from the shared
    // install manager. nil when no operation is running. Drives the per-app
    // status line (Downloading… / Installing… / Cleaning up… / Done) the user
    // asked to see under each app while it updates, mirroring the Installed
    // screen so big, slow packages show what's happening instead of a bare
    // spinner.
    var progress: InstallProgress? = nil

    @State private var isHoveringUpdate = false
    @State private var isHoveringPark = false
    // Drives the Park options dialogs (a plain Button + confirmationDialog is
    // used instead of a Menu so the button gets a reliable hover effect).
    @State private var showParkOptions = false
    @State private var showParkDurationOptions = false

    // Install/updated date pill, matching the Installed screen. Labeled
    // "Updated" for outdated rows and "Installed" otherwise (brew exposes a
    // single timestamp). nil date → omit the pill.
    private var dateText: String? {
        guard let date = package.installedDate else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }

    // Tint for the status icon + label: accent while in flight, green on
    // success, red on failure (matches InstalledRowView).
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

    // True for the .failed phase. The full error is shown in the dedicated red
    // failure banner below, so the compact status line suppresses .failed to
    // avoid surfacing the same error twice.
    private func isFailedPhase(_ phase: InstallProgress.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow

            // Live per-app status while this app's upgrade is in flight (the
            // status indicator the user asked for). Shows the current phase
            // (Downloading…, Installing…, Cleaning up…, Done) with a matching
            // icon and a small inline spinner so large, slow packages clearly
            // show what's happening. Success/failure linger briefly (handled by
            // the manager) before clearing. The dedicated red failure banner
            // below still carries the full error text, so we suppress this
            // line's own failed state to avoid showing the error twice.
            if let progress, !isFailedPhase(progress.phase) {
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
                        Spacer(minLength: 0)
                    }
                    // Bright-green flowing progress bar shown the whole time the
                    // upgrade is in flight (download → verify → install →
                    // cleanup). Indeterminate by design — brew has no single
                    // reliable percentage across those phases — so it conveys
                    // "still working" alongside the textual phase above. Hidden
                    // once the row reaches Done/Failed.
                    if progress.isActive {
                        GreenDashProgressBar(
                            tint: progress.isUninstall
                                ? .red
                                : Color(red: 0.16, green: 0.86, blue: 0.30)
                        )
                        .frame(height: 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Inline failure banner: shows when a prior upgrade attempt failed so
            // the user sees WHY instead of the row silently staying outdated.
            if let msg = failureMessage, !msg.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        // Card styling so each update reads as its own tile, matching the
        // Mac Store/Other Apps rows. The inner elements supply their own
        // horizontal padding, so the card adds only a vertical breathing pad
        // plus the rounded background.
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var mainRow: some View {
        HStack(spacing: 12) {
            // Multi-select checkbox (Updates Available only). Extra trailing
            // padding gives a clear gap between the checkbox and the app
            // icon/name so the two are not easy to mis-click.
            if isSelectable {
                Button {
                    onToggleSelect(package)
                } label: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .padding(.trailing, 8)
            }

            // Only the icon + name/version block opens the detail card. The
            // tap target is isolated here (not the whole row) so the empty gap
            // around the checkbox no longer launches the detail view by mistake.
            HStack(spacing: 12) {
                AppIconView(token: package.token, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(InstalledRowView.displayName(for: package.token))
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
                }
                // Size + date metadata row — matched 1:1 to the Installed screen
                // (own line, internaldrive + calendar pills, .titleAndIcon).
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
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap(package) }

            Spacer()

            if isSelectable {
                // Per-row Update action with in-flight spinner.
                if isBusy {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 80)
                } else {
                    HStack(spacing: 8) {
                        Button {
                            onUpdate(package)
                        } label: {
                            Label("Update", systemImage: "arrow.up.circle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isHoveringUpdate ? Color.white : Color.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    isHoveringUpdate
                                        ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(Color.accentColor.opacity(0.12)),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringUpdate = $0 }
                        .help("Update this package to the latest version now.")

                        // Park button: a menu styled like the Update button so
                        // the action is discoverable (no hidden right-click).
                        // Picking an option holds this package's version and
                        // skips it in Update All until it auto-resurfaces.
                        if onPark != nil {
                            parkButton
                        }
                    }
                }
            } else {
                // Up-to-date affordance: a calm status check.
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }

            // Chevron is a tappable affordance that also opens the detail card,
            // so the user has a clear "open" target without the whole row (and
            // the empty space around the checkbox) being tappable.
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .onTapGesture { onTap(package) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // Park button next to Update. It's a menu so the user can choose how long to
    // hold the package, but it reads and hovers like a button. The .help tooltip
    // explains what parking does on hover.
    // A plain Button (NOT a Menu) so it gets a reliable hover effect on macOS,
    // matching the Update button. Tapping opens a confirmationDialog to choose
    // how long to hold the package; "For a set time" opens a duration dialog.
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
                    .padding(.vertical, 5)
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
}

// MARK: - UpdatesView
//
// The "Updates" screen under Maintenance. Card-style, updates-only — it mirrors
// the Mac Store/Other Apps page so the two update screens look like siblings:
//  • A single "Updates available" section (count pill header) listing every
//    installed cask/formula that is outdated. Each row is multi-selectable
//    (leading checkbox) and has its own Update button; the header bar offers
//    "Update Selected" and "Update All".
//  • When nothing is outdated, a calm "all caught up" card is shown instead.
//
// There is intentionally NO full "Up to Date" / all-installed list here — that
// lives on the Installed screen. Keeping this page updates-only is what stops
// it from looking like a duplicate of Installed.
//
// Auto-refresh & move: upgrades go through appData.startInstall(...,
// isUpgrade: true, ...), whose completion runs refreshInstalled(). That flips
// the package's isOutdated to false, so SwiftUI re-derives `outdated` and the
// just-updated row simply drops out of the list with no manual bookkeeping.
struct UpdatesView: View {
    @Environment(AppDataService.self) var appData
    var onPackageTapped: ((InstalledPackage) -> Void)?
    // Toolbar search text, scoped to THIS page only: it filters the update
    // lists in place (by name / token) instead of triggering a global catalog
    // search. Bound from the shared search field by DetailRouter.
    var searchText: Binding<String> = .constant("")

    // Case-insensitive match of the live search query against a package name or
    // token. Empty query matches everything.
    private func matchesSearch(_ pkg: InstalledPackage) -> Bool {
        let q = searchText.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return InstalledRowView.displayName(for: pkg.token).lowercased().contains(q)
            || pkg.token.lowercased().contains(q)
    }

    // Mirrors the Settings toggle: when on, ForgedBrew also checks apps that update
    // themselves (brew's `--greedy`). Surfaced here as a quick inline switch so
    // the user can flip it right from the Updates screen. Default true.
    @AppStorage("forgedbrewIncludeSelfUpdatingApps") private var includeSelfUpdatingApps: Bool = true

    // Tokens the user has checked in the Updates Available section.
    @State private var selection = Set<String>()

    // Sort order for the lower "Up to Date" (full installed) section. The top
    // "Updates Available" section stays alphabetical by name regardless.
    // Persisted and shared with the Installed screen's default.
    // "Update All" now runs through the shared per-row install manager (same as
    // "Update Selected"), so there's no terminal-style sheet anymore. This task
    // handle just guards against a double-trigger while the batch is kicking off
    // and feeds `anyUpgradeInFlight` for the toolbar disabled-state.
    @State private var upgradeTask: Task<Void, Never>? = nil

    private var outdated: [InstalledPackage] {
        // Parked packages are held out of the Updates list (and Update All)
        // even though they're still outdated — they live in the Parked view.
        // The top section is always alphabetical (the sort control only governs
        // the lower full-installed list).
        PackageSortOrder.name.sorted(appData.outdatedExcludingParked().filter(matchesSearch))
    }

    // Selection scoped to rows that are still outdated (a token can leave the
    // top list mid-flight once its upgrade finishes; we never want to act on a
    // stale selection).
    private var selectedOutdated: [InstalledPackage] {
        outdated.filter { selection.contains($0.token) }
    }

    private var allOutdatedSelected: Bool {
        !outdated.isEmpty && selection.count == outdated.count
    }

    // True while any upgrade is running (per-row or the batch sheet), used to
    // disable the toolbar actions.
    private var anyUpgradeInFlight: Bool {
        upgradeTask != nil || outdated.contains { appData.isOperationInFlight(token: $0.token) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                // Parked Homebrew packages sit at the top (held out of the
                // Updates list below), exactly like the Mac Store/Other Apps
                // page shows its parked apps. Only Homebrew parks appear here.
                parkedSection

                if appData.installedPackages.isEmpty {
                    emptyState
                } else if outdated.isEmpty {
                    allCaughtUpState
                } else {
                    updatesSection
                }
            }
            .padding(20)
        }
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
        // the queued operation resumes via the SUDO_ASKPASS helper. This must be
        // present on every screen that can start an upgrade, otherwise the
        // operation stalls in the .needsPassword phase with no way to continue.
        .sheet(item: sudoRequestBinding) { request in
            SudoPasswordSheet(
                request: request,
                validate: { await appData.validateSudoPassword($0) }
            ) { password in
                appData.provideSudoPassword(password, for: request)
            }
        }
        // Keep the selection clean: drop any token that is no longer outdated
        // (it just finished upgrading and moved to the bottom list).
        .onChange(of: outdated.map(\.token)) { _, tokens in
            let valid = Set(tokens)
            selection = selection.intersection(valid)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // Title row: refresh sits just to the right of the page name.
                HStack(spacing: 12) {
                    PageTitleLabel(title: "Homebrew Updates")
                    PageRefreshButton("Re-scan", isWorking: appData.isLoadingInstalled) {
                        Task { await appData.refreshInstalled() }
                    }
                    Spacer()
                }
                Text(outdated.isEmpty
                     ? "Everything is up to date"
                     : "\(outdated.count) update\(outdated.count == 1 ? "" : "s") available")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Quick inline mirror of the Settings toggle. Re-checks the outdated
            // list immediately on change so the lists update in place.
            Toggle(isOn: $includeSelfUpdatingApps) {
                Text("Include apps that update themselves")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .tint(Color(red: 0.20, green: 0.55, blue: 0.34))
            .controlSize(.mini)
            .fixedSize()
            .help("Some apps (Microsoft Office, Chrome, Claude) update themselves, so Homebrew hides them by default. Turn on to check them too — they may appear even when already current.")
            .onChange(of: includeSelfUpdatingApps) { _, _ in
                Task { await appData.refreshInstalled() }
            }

            // Batch action bar (only meaningful when something is outdated).
            if !outdated.isEmpty {
                HStack(spacing: 12) {
                    Button(allOutdatedSelected ? "Deselect All" : "Select All") {
                        if allOutdatedSelected {
                            selection.removeAll()
                        } else {
                            selection = Set(outdated.map(\.token))
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(anyUpgradeInFlight)

                    Text("\(selection.count) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        updateSelected()
                    } label: {
                        Label("Update Selected", systemImage: "arrow.up.circle")
                            .font(.system(size: 12, weight: .semibold))
                            // Grey when nothing is selected, darker green when
                            // something is. White text on green reads clearly;
                            // muted text on grey signals the inactive state.
                            .foregroundStyle(selectedOutdated.isEmpty ? Color.secondary : Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selectedOutdated.isEmpty
                                    ? AnyShapeStyle(Color.secondary.opacity(0.20))
                                    : AnyShapeStyle(Color(red: 0.13, green: 0.55, blue: 0.24)),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedOutdated.isEmpty || anyUpgradeInFlight)

                    Button {
                        startUpgradeAll()
                    } label: {
                        Label("Update All", systemImage: "arrow.up.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(outdated.isEmpty || anyUpgradeInFlight)
                }
            }
        }
    }

    // MARK: - Failure surfacing

    // Derives a user-facing error string for a package whose most recent upgrade
    // attempt failed. AppDataService records this in installProgress[token] with
    // a .failed(message) phase. Returns nil when there is no recorded failure or
    // an operation is currently in flight (so we don't flash a stale error).
    private func upgradeFailureMessage(for token: String) -> String? {
        guard !appData.isOperationInFlight(token: token),
              let progress = appData.installProgress[token] else { return nil }
        if case .failed(let message) = progress.phase {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Update failed. Open this package for the full log." : trimmed
        }
        return nil
    }

    // MARK: - Updates section (card style)
    //
    // Card-style list of the outdated Homebrew packages, mirroring the Mac
    // Store/Other Apps page (a "Updates available" section header with a count
    // pill, then a LazyVStack of rows). The full "Up to Date" list was removed
    // so this screen reads as an Updates page, not a duplicate of Installed.

    // MARK: - Parked section
    //
    // Parked Homebrew packages, shown at the top of the Updates page (held out
    // of the Updates list below). Mirrors the Mac Store/Other Apps page's
    // parked section — and like that page, ONLY shows Homebrew parks here.
    // Empty when nothing is parked. The dedicated Parked screen still shows
    // both Homebrew and Mac/Other parks together.
    @ViewBuilder
    private var parkedSection: some View {
        let parked = appData.parkedPackages()
        if !parked.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Parked packages", systemImage: "parkingsign.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text("These Homebrew packages are held out of the Updates list below. ForgedBrew keeps checking, so a parked package reappears when a newer version ships or its hold expires.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVStack(spacing: 12) {
                    ForEach(parked, id: \.record.id) { item in
                        ParkedRowView(record: item.record, package: item.package)
                    }
                }
                Divider().padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Updates available", count: outdated.count)
            LazyVStack(spacing: 12) {
                ForEach(outdated) { pkg in
                    UpdateRowView(
                        package: pkg,
                        isSelectable: true,
                        isSelected: selection.contains(pkg.token),
                        isBusy: appData.isOperationInFlight(token: pkg.token),
                        failureMessage: upgradeFailureMessage(for: pkg.token),
                        onToggleSelect: { toggle($0.token) },
                        onUpdate: { update($0) },
                        onTap: { onPackageTapped?($0) },
                        onPark: { p, type, duration in
                            Task { await appData.park(package: p, parkType: type, duration: duration) }
                        },
                        progress: appData.installProgress[pkg.token]
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: outdated.map(\.token))
    }

    // A section title with a count pill (e.g. "Updates available  3").
    // Matches the Mac Store/Other Apps page's section headers.
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

    // MARK: - Empty / caught-up states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No installed packages")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Install some apps or formulae and they'll show up here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var allCaughtUpState: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're all caught up")
                    .font(.system(size: 13, weight: .semibold))
                Text("Every installed package is on its latest version.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.green.opacity(0.3), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

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

    private func toggle(_ token: String) {
        if selection.contains(token) {
            selection.remove(token)
        } else {
            selection.insert(token)
        }
    }

    // Upgrades a single package via the shared install manager. On completion
    // the manager refreshes installed state, flipping isOutdated → false so the
    // row auto-moves to the Up to Date section.
    //
    // We always gate on the session password first: the first update action of a
    // session prompts once (even if this particular app wouldn't strictly need
    // root), caches it in memory, and reuses it silently thereafter. Cancelling
    // the prompt (nil) aborts the update.
    private func update(_ pkg: InstalledPackage) {
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

    // Kicks off an upgrade for each selected outdated package. Prompts once for
    // the session password up front (cancelling aborts the whole batch), then
    // starts each upgrade with the cached password.
    private func updateSelected() {
        let packages = selectedOutdated
        // NOTE: we intentionally do NOT clear `selection` here. The checked
        // boxes stay checked (and are auto-disabled via .disabled(isBusy) on
        // each row) while the update runs, so the user keeps seeing exactly
        // which apps are being updated. Each row drops its check automatically
        // once its upgrade completes and the refresh removes it from `outdated`
        // — the .onChange(of: outdated) prune intersects `selection` with the
        // still-outdated tokens, so finished apps fall out of the list AND out
        // of the selection together.
        Task {
            guard let password = await appData.ensureSessionSudoPassword() else { return }
            // Batch path: upgrades run with per-app cleanup disabled and a single
            // shared `brew cleanup` runs after they all finish. This is the fix
            // for the multi-app "stuck on Cleaning up…" hang.
            appData.startBatchUpgrade(packages: packages, sudoPassword: password)
        }
    }

    // "Update All" now uses the SAME per-row progress flow as "Update Selected"
    // (each app shows its own live phase + progress bar and settles to Done),
    // instead of streaming brew's combined output into a terminal-style sheet.
    // It upgrades every non-parked outdated package through startBatchUpgrade,
    // which runs them with per-app cleanup disabled and a single shared
    // `brew cleanup` at the end — the same path that fixed the multi-app
    // "stuck on Cleaning up…" hang. Prompts once for the session password first
    // (cancelling aborts the whole batch).
    private func startUpgradeAll() {
        upgradeTask?.cancel()
        upgradeTask = Task {
            guard let password = await appData.ensureSessionSudoPassword() else {
                await MainActor.run { upgradeTask = nil }
                return
            }
            // Upgrade only the non-parked outdated packages so brew never touches
            // (and can't downgrade/clobber) anything the user has parked. Each
            // row shows its own progress HUD via the shared install manager.
            let packages = appData.outdatedExcludingParked()
            appData.startBatchUpgrade(packages: packages, sudoPassword: password)
            await MainActor.run {
                upgradeTask = nil
            }
        }
    }
}
