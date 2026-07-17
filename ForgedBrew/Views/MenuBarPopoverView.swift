import SwiftUI
import AppKit

// MARK: - Menu bar popover
//
// The content of the menu bar extra's popover — ForgedBrew's glanceable "what
// needs attention?" surface. The AppKit side (status item, popover, right-click
// menu) lives in StartupSettings.
//
// SHAPE: a short list of collapsible sections, not a flat dump. A machine with
// a few dozen outdated packages would make a flat list taller than the screen,
// so each section is one line until asked to expand, and only ONE is open at a
// time. Everything scrolls inside a single outer ScrollView — nested scroll
// views inside a popover fight each other for the wheel.
//
// The Updates section mirrors the icon's badge EXACTLY: outdatedExcludingParked()
// plus AppUpdateService.visibleUpdates(), the same expression as
// ForgedBrewApp.availableUpdateTotal. A count that didn't match its own list
// would be worse than no count at all.
//
// Homebrew packages get a real Update button. Mac/other apps are
// awareness-only (see AppUpdateService), so they get "Open App" — the same
// honest framing as AppUpdatesView, which opens the app so it can update itself
// rather than pretending ForgedBrew can do it.
//
// THE WINDOWLESS CONSTRAINT drives the rest of this file. The popover is
// reachable with no window on screen (menu-bar-only / headless launch), so
// anything it offers has to work without one. That's why the admin-password
// prompt is inline here instead of the `.sheet(item: sudoRequestBinding)` the
// windowed screens use: ensureSessionSudoPassword() parks a continuation and
// waits for a view to answer it, and with no window there is no sheet, no
// answer, and the update Task hangs forever.
struct MenuBarPopoverView: View {
    // Shows the main window and closes the popover.
    let onOpenWindow: () -> Void
    // Quits via StartupSettings.requestQuit, so the menu-bar keep-alive rule in
    // applicationShouldTerminate lets the quit through instead of cancelling it.
    let onQuit: () -> Void

    @Environment(AppDataService.self) private var appData

    // AppUpdateService — unlike AppDataService — is never put in the
    // environment; every call site reads the singleton. It's @MainActor
    // @Observable, so reading its properties in `body` still registers for
    // observation and the rows stay live.
    private var appUpdates: AppUpdateService { .shared }

    // Which section is open, or nil for none. Accordion rather than independent
    // toggles: with several sections expanded the popover grows past the useful
    // height of a menu bar surface.
    @State private var expanded: PopoverSection? = nil

    private enum PopoverSection: String, Identifiable {
        case diagnostics, updates, appearance
        var id: String { rawValue }
    }

    private var brewUpdates: [InstalledPackage] { appData.outdatedExcludingParked() }
    private var otherUpdates: [AppUpdate] { appUpdates.visibleUpdates() }
    private var updateCount: Int { brewUpdates.count + otherUpdates.count }

    private var isBusy: Bool { appData.isRefreshingEverything || appUpdates.isScanning }

    var body: some View {
        VStack(spacing: 0) {
            // The password prompt takes over the whole popover rather than
            // stacking under the sections: it's modal in intent (an update is
            // parked waiting on it) and the popover is too small to show both
            // without the field getting lost.
            if let request = appData.pendingSudoRequest {
                MenuBarSudoPrompt(
                    request: request,
                    validate: { await appData.validateSudoPassword($0) }
                ) { password in
                    appData.provideSudoPassword(password, for: request)
                }
            } else {
                header
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        diagnosticsSection
                        updatesSection
                        appearanceSection
                    }
                    .padding(.vertical, 4)
                }
                // Cap the popover's height; the single outer scroll absorbs
                // whatever the open section adds.
                .frame(maxHeight: 420)
                Divider()
                footer
            }
        }
        .frame(width: 340)
        // An NSHostingController is its own SwiftUI tree — it inherits nothing
        // from the WindowGroup, so the app's spinner style has to be re-applied
        // here or every ProgressView falls back to the AppKit
        // NSProgressIndicator and ghosts a grey spinner. Same reason the sheets
        // re-apply it; see SudoPasswordSheet.
        .progressViewStyle(.forgedbrew)
        // Kick a brew doctor run the first time the popover is ever opened.
        // refreshDoctor() no-ops when a report is already cached, so this costs
        // the (network-bound, up-to-90s) check once per session rather than on
        // every click.
        .task { await appData.refreshDoctor() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "mug.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StartupSettings.shared.menuBarIconStyle.swatch)

            VStack(alignment: .leading, spacing: 1) {
                Text("ForgedBrew")
                    .font(.system(size: 13, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Amber like the other actions — it's a button, not an ornament.
            Button(action: refresh) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(MenuBarTextButtonStyle())
            .disabled(isBusy)
            .help("Refresh everything")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // The header's one-line status. The in-flight sweep wins over the update
    // count — while it's running, what it's doing is the more useful fact.
    private var summary: String {
        if let status = appData.fullMaintenanceStatus { return status }
        if isBusy { return "Checking for updates…" }
        switch updateCount {
        case 0:  return "Everything's up to date"
        case 1:  return "1 update available"
        default: return "\(updateCount) updates available"
        }
    }

    // MARK: - Diagnostics section

    private var diagnosticsSection: some View {
        VStack(spacing: 0) {
            sectionRow(
                icon: doctorStatus.icon,
                tint: doctorStatus.tint,
                title: "Homebrew Health",
                subtitle: doctorStatus.text,
                section: .diagnostics
            )
            if expanded == .diagnostics {
                VStack(alignment: .leading, spacing: 6) {
                    if let report = appData.doctorReport {
                        if report.isClean {
                            Text("brew doctor found nothing to report.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            // Honest count: every finding brew doctor reported,
                            // named. Most Macs carry a couple of benign warnings
                            // — we say what they are rather than hiding them or
                            // second-guessing which ones matter.
                            ForEach(report.findings) { finding in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(ActionColors.update)
                                        .frame(width: 12)
                                    Text(MaintenanceView.doctorIssueLabel(for: finding))
                                        .font(.system(size: 11))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if report.systemReady {
                                // brew prints "ready to brew" even alongside
                                // warnings; passing that on stops a couple of
                                // cosmetic notes reading as a broken install.
                                Text("Your system is still ready to brew.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if appData.isRunningDoctor {
                        Text("Running brew doctor…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Homebrew's health hasn't been checked yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        if let checked = appData.doctorCheckedAt {
                            Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Re-check") {
                            Task { await appData.refreshDoctor(force: true) }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(MenuBarTextButtonStyle())
                        .disabled(appData.isRunningDoctor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var doctorStatus: (icon: String, tint: Color, text: String) {
        if appData.isRunningDoctor && appData.doctorReport == nil {
            return ("hourglass", .secondary, "Checking…")
        }
        guard let report = appData.doctorReport else {
            return ("questionmark.circle", .secondary, "Not checked yet")
        }
        if report.isClean {
            return ("checkmark.circle.fill", ActionColors.installed, "Homebrew is healthy")
        }
        let n = report.findings.count
        return ("exclamationmark.triangle.fill", ActionColors.update,
                "\(n) issue\(n == 1 ? "" : "s") found")
    }

    // MARK: - Updates section

    private var updatesSection: some View {
        VStack(spacing: 0) {
            sectionRow(
                icon: updateCount == 0 ? "checkmark.circle.fill" : "arrow.down.circle.fill",
                tint: updateCount == 0 ? ActionColors.installed : ActionColors.update,
                title: "Updates",
                subtitle: updateCount == 0
                    ? "Everything's up to date"
                    : "\(updateCount) available",
                section: .updates
            )
            if expanded == .updates {
                VStack(alignment: .leading, spacing: 0) {
                    updateAllRow
                    if !brewUpdates.isEmpty {
                        subheader("Homebrew")
                        ForEach(brewUpdates) { package in
                            MenuBarBrewRow(
                                package: package,
                                progress: appData.installProgress[package.token]
                            ) {
                                update(package)
                            }
                        }
                    }
                    if !otherUpdates.isEmpty {
                        subheader("Other Apps")
                        ForEach(otherUpdates) { update in
                            MenuBarAppRow(update: update) {
                                appUpdates.openApp(for: update)
                            }
                        }
                    }
                    if updateCount == 0 {
                        Text("Nothing to update. You can still run a clean-up above.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    // The two whole-list actions, alongside the per-app Update buttons below.
    //
    // Refresh All is repeated here even though the header already has the ↻
    // glyph: once the Updates section is expanded, the header is scrolled away
    // from where the user is looking, and "this list looks stale, re-check it"
    // is the obvious next thought while reading the list itself.
    //
    // Update All is worded so the destructive half isn't a surprise — it purges
    // ALL cached downloads, so the next install re-downloads.
    private var updateAllRow: some View {
        HStack(spacing: 4) {
            Button(action: updateAllAndCleanUp) {
                HStack(spacing: 5) {
                    if appData.isRunningFullMaintenance {
                        ProgressView().controlSize(.small)
                    }
                    Text("Update All & Purge Cache")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(MenuBarTextButtonStyle())
            .disabled(appData.isRunningFullMaintenance || isUpdatingAny)

            Button(action: refresh) {
                HStack(spacing: 5) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text("Refresh All")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(MenuBarTextButtonStyle())
            .disabled(isBusy)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .help("Runs brew update, upgrades everything outdated, then removes every cached download (they re-download next time).")
    }

    private func subheader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    // MARK: - Appearance section

    private var appearanceSection: some View {
        VStack(spacing: 0) {
            sectionRow(
                icon: "paintpalette.fill",
                tint: StartupSettings.shared.menuBarIconStyle.swatch,
                title: "Appearance",
                subtitle: StartupSettings.shared.menuBarIconStyle.label,
                section: .appearance
            )
            if expanded == .appearance {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            swatch(style)
                        }
                        Spacer()
                    }
                    Text(StartupSettings.shared.menuBarIconStyle == .monochrome
                         ? "Monochrome follows your menu bar — light or dark, and dimmed on inactive displays."
                         : "A fixed colour looks the same in every menu bar. Monochrome is the only one that adapts.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private func swatch(_ style: MenuBarIconStyle) -> some View {
        let isSelected = StartupSettings.shared.menuBarIconStyle == style
        return Button {
            StartupSettings.shared.menuBarIconStyle = style
        } label: {
            Circle()
                .fill(style.swatch)
                .frame(width: 18, height: 18)
                // Hairline so a light swatch still reads against the popover.
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                        .padding(-2.5)
                )
        }
        .buttonStyle(.plain)
        .help(style.label)
    }

    // MARK: - Section row

    private func sectionRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String?,
        section: PopoverSection
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                expanded = (expanded == section) ? nil : section
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded == section ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarRowButtonStyle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open ForgedBrew", action: onOpenWindow)
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(MenuBarTextButtonStyle())
            Spacer(minLength: 4)
            // Quit stays grey: it's the one action here you don't want the eye
            // drawn to, so it gets the hover affordance without the amber.
            Button("Quit", action: onQuit)
                .font(.system(size: 11))
                .buttonStyle(MenuBarTextButtonStyle(tint: .secondary))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    // True while any listed package is mid-upgrade, so the sweep doesn't stack
    // a second batch on top of a running one.
    private var isUpdatingAny: Bool {
        brewUpdates.contains { appData.installProgress[$0.token]?.isActive == true }
    }

    // MARK: - Actions

    private func refresh() {
        Task { await appData.refreshEverything() }
    }

    // Upgrades one package. Mirrors UpdatesView.update(_:) — the session
    // password gate comes first and nil (cancel) aborts — the only difference
    // being that here the prompt it raises is answered by this popover.
    private func update(_ package: InstalledPackage) {
        Task {
            guard let password = await appData.ensureSessionSudoPassword() else { return }
            appData.startInstall(
                token: package.token,
                isUpgrade: true,
                isFormula: package.type == .formula,
                sudoPassword: password
            )
        }
    }

    // brew update → upgrade everything outdated → purge the download cache.
    // The service owns the sequencing; we only gate on the password first, the
    // same as every other privileged action.
    private func updateAllAndCleanUp() {
        Task {
            guard let password = await appData.ensureSessionSudoPassword() else { return }
            appData.startUpdateAllAndCleanUp(sudoPassword: password)
        }
    }
}

// MARK: - Button styles
//
// Two styles, one rule: every action in the popover is TINTED TEXT that
// highlights on hover — no filled pills. Colour carries the meaning (amber =
// updates something, blue = opens something, grey = Quit) and hover carries the
// affordance. An earlier pass mixed solid pills with text links and the result
// read as two different designs sharing a window.
//
// Both share one trap. A ButtonStyle is NOT a View, so @State declared directly
// on the style is never installed in SwiftUI's graph — it compiles, reads
// naturally, and simply never updates. Hover tracking therefore lives in a
// nested view in each style. Don't hoist it back onto the style.

// Menu-like hover highlight for the collapsible section rows.
private struct MenuBarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(hovering || configuration.isPressed ? 0.09 : 0))
                        .padding(.horizontal, 6)
                )
                .onHover { hovering = $0 }
        }
    }
}

// Borderless text/icon action (Re-check, Open ForgedBrew, the refresh glyph).
// Amber by default — these read as inert grey labels otherwise, which is what
// made "Re-check" and "Open ForgedBrew" look like captions rather than buttons.
// Deliberately sets no font: call sites keep their own sizing.
private struct MenuBarTextButtonStyle: ButtonStyle {
    var tint: Color = ActionColors.update

    func makeBody(configuration: Configuration) -> some View {
        TextBody(configuration: configuration, tint: tint)
    }

    private struct TextBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @State private var hovering = false
        // Custom styles don't dim themselves when .disabled() is applied, so
        // read it back and do it by hand.
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(tint.opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(tint.opacity(hovering && isEnabled ? 0.15 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Homebrew row

private struct MenuBarBrewRow: View {
    let package: InstalledPackage
    let progress: InstallProgress?
    let onUpdate: () -> Void

    private var displayName: String {
        InstalledRowView.displayName(for: package.token)
    }

    // The available version lives on outdatedInfo.currentVersion — "current" as
    // in "current upstream", not "currently installed". The installed one is
    // package.installedVersion.
    private var newVersion: String? { package.outdatedInfo?.currentVersion }

    private var failureMessage: String? {
        if case .failed(let message) = progress?.phase { return message }
        return nil
    }

    var body: some View {
        HStack(spacing: 9) {
            AppIconView(token: package.token, displayName: displayName, size: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                subtitle
            }

            Spacer(minLength: 6)
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let progress, progress.isActive {
            HStack(spacing: 4) {
                Image(systemName: progress.statusSymbol)
                    .font(.system(size: 9))
                Text(progress.statusLabel)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        } else if let failureMessage {
            Text(failureMessage)
                .font(.system(size: 10))
                .foregroundStyle(ActionColors.destructive)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(failureMessage)
        } else {
            Text(versionLine)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var versionLine: String {
        let installed = package.installedVersion ?? "—"
        guard let newVersion else { return installed }
        return "\(installed) → \(newVersion)"
    }

    @ViewBuilder
    private var action: some View {
        if let progress, progress.isActive {
            ProgressView()
                .controlSize(.small)
        } else {
            Button(failureMessage == nil ? "Update" : "Retry", action: onUpdate)
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(MenuBarTextButtonStyle())
        }
    }
}

// MARK: - Mac / other app row

private struct MenuBarAppRow: View {
    let update: AppUpdate
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            MenuBarAppIcon(path: update.appPath, size: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(update.appName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(versionLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            // "Open App", not "Update": ForgedBrew doesn't install these — it
            // launches the app so the app can update itself. Matching
            // AppUpdatesView's wording keeps the promise honest.
            //
            // Blue, not amber, for the same reason it's blue in AppUpdatesView:
            // amber means "this updates something" throughout the app, and this
            // button doesn't — it just opens the app.
            Button("Open App", action: onOpen)
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(MenuBarTextButtonStyle(tint: ActionColors.website))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // availableVersion is nil when we can tell an update exists but can't read
    // the new version number (an App Store app with no `mas` installed), so the
    // row shows what we do know rather than an em-dash arrow into nothing.
    private var versionLine: String {
        guard let available = update.availableVersion else {
            return "\(update.installedVersion) installed · update available"
        }
        return "\(update.installedVersion) → \(available)"
    }
}

// MARK: - App icon (by path)

// The .app-path counterpart to AppIconView (which keys off a brew token).
// Same shape as the hand-rolled icon in AppUpdatesView.
private struct MenuBarAppIcon: View {
    let path: String
    let size: CGFloat

    @State private var icon: NSImage? = nil

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: size, height: size)
            }
        }
        // Cache-only peek: synchronous but free for an already-resolved path.
        .onAppear {
            if icon == nil, let cached = AppIconService.shared.cachedIcon(path: path) {
                icon = cached
            }
        }
        // The real resolve does a disk match plus NSWorkspace.icon(forFile:),
        // which must never run on the main thread inside a body evaluation —
        // that's the scroll-freeze AppIconService.resolvedIcon exists to avoid.
        .task(id: path) {
            if icon == nil {
                let resolved = await AppIconService.shared.resolvedIcon(path: path)
                if !Task.isCancelled, let resolved { icon = resolved }
            }
        }
    }
}

// MARK: - Inline admin-password prompt

// A compact, popover-sized restatement of SudoPasswordSheet. It deliberately
// duplicates the sheet's shape rather than reusing it: the sheet is a fixed
// 460×360 and presenting a real sheet needs a window, which is exactly what the
// popover may not have. The CONTRACT is identical — validate before accepting
// so a wrong password is never cached, and hand back nil on cancel so
// ensureSessionSudoPassword's continuation always resumes.
private struct MenuBarSudoPrompt: View {
    let request: SudoRequest
    let validate: (String) async -> Bool
    let onSubmit: (String?) -> Void

    @State private var password = ""
    @State private var isVerifying = false
    @State private var showWrongPassword = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ActionColors.update)
                Text("Administrator Password")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            Text("Enter your Mac login password so ForgedBrew can finish the update.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Mac password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .disabled(isVerifying)
                .onSubmit(submit)
                .onChange(of: password) { _, _ in
                    if showWrongPassword { showWrongPassword = false }
                }

            if showWrongPassword {
                Text("That password was not accepted. Please try again.")
                    .font(.system(size: 10))
                    .foregroundStyle(ActionColors.destructive)
            }

            Text("Kept in memory for this session only, never saved to disk or your Keychain.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if isVerifying {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onSubmit(nil) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isVerifying)
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isVerifying)
            }
        }
        .padding(14)
        // The popover's window is made key on show (see
        // StartupSettings.togglePopover) — without that, in .accessory mode this
        // field would look focused and silently swallow every keystroke.
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard !password.isEmpty, !isVerifying else { return }
        isVerifying = true
        showWrongPassword = false
        Task {
            let ok = await validate(password)
            isVerifying = false
            if ok {
                onSubmit(password)
            } else {
                // Reject in place so a bad password is never handed back (and so
                // never cached): clear, explain, refocus.
                showWrongPassword = true
                password = ""
                fieldFocused = true
            }
        }
    }
}

