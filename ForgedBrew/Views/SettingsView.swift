import SwiftUI
import AppKit

// A card outline that stays subtle in dark mode (where the faint fill already
// separates the card from the background) but becomes clearly visible in light
// mode, where a near-white fill on a white window would otherwise disappear.
private struct CardStroke: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 12

    private var strokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.18)
    }

    private var lineWidth: CGFloat {
        colorScheme == .dark ? 0.5 : 1.0
    }

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(strokeColor, lineWidth: lineWidth)
        )
    }
}

private extension View {
    func cardStroke(cornerRadius: CGFloat = 12) -> some View {
        modifier(CardStroke(cornerRadius: cornerRadius))
    }
}

// Same light/dark-aware outline as CardStroke, but clipped to a Capsule for
// status pills (which are near-invisible on a white window in light mode).
private struct PillStroke: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    private var strokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.18)
    }

    private var lineWidth: CGFloat {
        colorScheme == .dark ? 0.5 : 1.0
    }

    func body(content: Content) -> some View {
        content.overlay(
            Capsule().strokeBorder(strokeColor, lineWidth: lineWidth)
        )
    }
}

private extension View {
    func pillStroke() -> some View {
        modifier(PillStroke())
    }
}

// Communicates the Settings context (standalone menu-bar window vs in-app
// sidebar) down to the shared tab scaffold without threading a flag through
// every tab. true → menu-bar window (shows the "changes saved automatically"
// note at the top of each tab).
private struct SettingsIsMenuBarWindowKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var settingsIsMenuBarWindow: Bool {
        get { self[SettingsIsMenuBarWindowKey.self] }
        set { self[SettingsIsMenuBarWindowKey.self] = newValue }
    }
}

// App settings, organized as a tabbed pane. The same view is used in two
// places (both wired to identical content):
//   1. The "Settings" row in the sidebar (rendered in the detail area), and
//   2. The standard macOS Settings window opened with ⌘, / ForgedBrew ▸ Settings…
//
// Design split (see #10): the app menu holds COMMANDS (Check for Updates,
// Settings…) while every PREFERENCE lives here in tabbed Settings. We do not
// scatter individual toggles across the menu bar.
//
// Tabs: General & Updates · App Locations · APIs · About.
// (A License tab is planned for the trial/licensing work and is intentionally
// omitted for now.)
struct SettingsView: View {
    // Optional "done" handler for the in-app (sidebar) context, where there is
    // no separate window to close — the host passes a closure that navigates
    // back to Home. In the standalone ⌘, Settings window this is nil and the
    // button simply dismisses the window.
    var onDone: (() -> Void)? = nil

    // Dismisses the standalone Settings window when present.
    @Environment(\.dismiss) private var dismiss

    // True in the standalone ⌘, / menu-bar Settings window (no onDone handler),
    // false in the in-app sidebar context. Drives both the per-tab "changes are
    // saved automatically" note and which footer button is shown.
    private var isMenuBarWindow: Bool { onDone == nil }

    var body: some View {
        VStack(spacing: 0) {
        TabView {
            // "General" and "Updates" share a single tab with clear section
            // headers so neither feels sparse.
            GeneralAndUpdatesSettingsTab()
                .tabItem { Label("General & Updates", systemImage: "gearshape") }

            // The folders ForgedBrew scans for installed apps.
            AppLocationsSettingsTab()
                .tabItem { Label("App Locations", systemImage: "folder") }

            // Optional API keys (e.g. SerpApi for richer screenshots).
            APIsSettingsTab()
                .tabItem { Label("APIs", systemImage: "key") }

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // A comfortable default for the ⌘, window; the sidebar host stretches
        // this to fill the detail column, so the min keeps the tabbed content
        // readable in both contexts.
        .frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Tell the shared tab scaffold which context it is in, so the menu-bar
        // window shows the "changes saved automatically" note on every tab.
        .environment(\.settingsIsMenuBarWindow, isMenuBarWindow)

            // Footer. Preferences persist live, so there is no "Save" action.
            //  • Sidebar (onDone set): NO footer at all — every tab shows a
            //    "Changes are automatically saved." note instead, and the user
            //    leaves via the sidebar whenever they like.
            //  • Menu-bar window (onDone nil): an "Exit" button that closes ONLY
            //    the Settings window gracefully and brings the main app forward,
            //    instead of dismiss() — which was tearing the whole app down.
            if isMenuBarWindow {
                Divider()
                HStack {
                    Spacer()
                    Button {
                        Self.closeSettingsWindowGracefully()
                    } label: {
                        Label("Exit", systemImage: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(.background)
    }

    // Closes the standalone ⌘, / menu-bar Settings window without going through
    // SwiftUI's dismiss() (which, in this app's menu-bar lifecycle, was
    // tearing the whole app down). We find the Settings window by its identifier
    // / title and order it out, then re-activate the app and bring the main
    // ForgedBrew window forward so the user lands back in the app, not on nothing.
    @MainActor
    private static func closeSettingsWindowGracefully() {
        // Find the standalone Settings window. SwiftUI's Settings scene window
        // identifies as "com.apple.SwiftUI.Settings"; we also fall back to the
        // current key window, since the Exit button can only be clicked there.
        let settingsWindow = NSApp.windows.first { win in
            let id = win.identifier?.rawValue ?? ""
            return id.localizedCaseInsensitiveContains("settings") || win.title == "Settings"
        } ?? NSApp.keyWindow

        // Bring a real app window forward first so focus has somewhere to land
        // (otherwise closing the key window can leave the app with no front window).
        if let main = NSApp.windows.first(where: {
            $0.canBecomeMain && $0 !== settingsWindow && $0.isVisible
        }) {
            main.makeKeyAndOrderFront(nil)
        }

        // Order out (not performClose) so we never trip the close-button-driven
        // terminate path in AppDelegate; the Settings scene is reusable and will
        // simply be recreated next time the user opens ⌘,.
        settingsWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Shared card chrome

// Reused container so every tab's sections look identical to the cards the app
// used before the tabbed redesign.
private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            content()
        }
        .padding(16)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cardStroke(cornerRadius: 12)
    }
}

// Common scroll + width wrapper so all tabs share padding and max content width.
private struct SettingsTabScaffold<Content: View>: View {
    @ViewBuilder var content: () -> Content

    // Both Settings surfaces (the sidebar pane and the standalone menu-bar
    // window) show a small note at the top of every tab making clear that edits
    // persist live, so neither needs a Save button.

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Completely private. ForgedBrew runs entirely on your Mac, collects no data, and nothing you do here ever leaves your computer.", systemImage: "lock.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    // White text on a deep forest-green box so the privacy
                    // promise stands out as a solid badge rather than tinted text.
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        Color(red: 0.09, green: 0.34, blue: 0.18),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label("Changes are automatically saved.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                content()
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - General & Updates
//
// Combines the former "General" tab (Appearance) and the former "Updates" tab
// (ForgedBrew self-update + self-updating-apps detection) into one pane. Every
// control from both tabs is preserved verbatim; they're simply grouped under
// the same scaffold with their existing section cards acting as headers.

private struct GeneralAndUpdatesSettingsTab: View {
    // --- General (Appearance) state ---
    // Shares the SAME key the sidebar's moon/sun button writes, so the two
    // controls stay in sync. true = dark, false = follow Light (system Aqua).
    // We do NOT use .onChange here: an @AppStorage value set from the Settings
    // window doesn't always deliver onChange to a sibling scene, which is why
    // the picker appeared dead. Instead each control mutates the value AND
    // applies the appearance in the same action, exactly like the sidebar
    // button does — so the effect is immediate regardless of scene.
    @AppStorage("forgedbrewPrefersDarkMode") private var isDark: Bool = true

    // --- Updates state ---
    // Whether to also check apps that update themselves (brew's `--greedy`).
    // Default true so ForgedBrew's count reflects every app that has an update.
    @AppStorage("forgedbrewIncludeSelfUpdatingApps") private var includeSelfUpdatingApps: Bool = true

    // --- Startup state ---
    // Backs the Launch-at-login and Keep-in-Dock toggles. A shared Observable so
    // it always reflects the real system state (login item plus activation policy).
    @State private var startup = StartupSettings.shared

    // --- System access state ---
    // Whether macOS has granted Full Disk Access (probed via the TCC dir read).
    // Refreshed on appear so it reflects changes the user makes in System
    // Settings while ForgedBrew is running.
    @State private var fdaGranted = false
    // Whether the `mas` (Mac App Store) CLI is installed. Surfaced here during
    // setup so users can add it up front rather than discovering it later on the
    // Mac Store/Other Apps screen.
    @State private var masInstalled = false
    // True while we're installing `mas` from the inline button.
    @State private var installingMas = false
    // Whether the `topgrade` CLI is installed. Powers the in-place "Update" /
    // "Update All Apps" actions on the Mac Store/Other Apps screen; surfaced
    // here during setup so users can add it up front.
    @State private var topgradeInstalled = false
    // True while we're installing `topgrade` from the inline button.
    @State private var installingTopgrade = false

    @Environment(AppDataService.self) private var appData
    // Shared Sparkle updater instance injected by ForgedBrewApp (same one the
    // menu bar's "Check for Updates…" command uses).
    @Environment(Updater.self) private var updater

    private func setDark(_ value: Bool) {
        isDark = value
        // Apply to every window the app owns so the change takes effect even
        // when triggered from the separate Settings window.
        let appearance: NSAppearance? = value ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        NSApp.appearance = appearance
        for window in NSApp.windows { window.appearance = appearance }
    }

    var body: some View {
        // Bindable view of the shared Sparkle updater so the auto-update
        // toggles below can write straight through to SPUUpdater.
        @Bindable var updater = updater
        return SettingsTabScaffold {
            // ===== General section =====
            sectionHeader("General")

            SettingsCard(title: "Appearance", systemImage: "circle.lefthalf.filled") {
                Text("Choose how ForgedBrew looks. This matches the quick light/dark toggle at the bottom of the sidebar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Plain buttons (not a Bool-bound Picker, which binds
                // unreliably) give a segmented look while guaranteeing the
                // action fires every time.
                HStack(spacing: 8) {
                    appearanceButton(title: "Light", systemImage: "sun.max", isSelected: !isDark) {
                        setDark(false)
                    }
                    appearanceButton(title: "Dark", systemImage: "moon", isSelected: isDark) {
                        setDark(true)
                    }
                    Spacer()
                }
            }

            // ===== Startup section (within General) =====
            SettingsCard(title: "Startup", systemImage: "power") {
                Toggle(isOn: $startup.launchAtLogin) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Load on startup")
                            .font(.system(size: 13, weight: .medium))
                        Text("Open ForgedBrew automatically when you log in to your Mac. macOS may ask you to confirm the login item the first time.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(Color(red: 0.20, green: 0.55, blue: 0.34))

                Divider()

                Toggle(isOn: $startup.keepInDock) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep in Dock")
                            .font(.system(size: 13, weight: .medium))
                        Text("Show the ForgedBrew icon in the Dock all the time, with the number of available updates as a badge. Turn this off to keep the Dock clear \u{2014} opening ForgedBrew from the menu bar will show a Dock icon only while its window is open.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(Color(red: 0.20, green: 0.55, blue: 0.34))

                Divider()

                Toggle(isOn: $startup.showInMenuBar) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show in menu bar")
                            .font(.system(size: 13, weight: .medium))
                        Text("Add a ForgedBrew icon to the menu bar, with the number of available updates beside it and a menu to open the app or quit. When this is on and ForgedBrew launches at login, it starts quietly in the menu bar without opening the window \u{2014} click the icon and choose \u{201C}Open ForgedBrew\u{201D} to bring it up.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(Color(red: 0.20, green: 0.55, blue: 0.34))

                Divider()

                // Login-item permission status + a jump to System Settings,
                // mirroring the Full Disk Access pattern on the Maintenance
                // screen. "Load on startup" only works once macOS has the login
                // item enabled under Login Items; this surfaces that state and
                // gives a one-click way to fix it if it was turned off in System
                // Settings.
                startupPermissionsRow
            }

            // ===== System access section (within General) =====
            // Two setup-time status rows mirroring the Maintenance Full Disk
            // Access banner: Full Disk Access and the optional `mas` CLI. Both
            // show a green "granted/installed" state when satisfied, or an
            // actionable button when not — so users can square these away while
            // first setting the app up rather than hunting for them later.
            SettingsCard(title: "System access", systemImage: "lock.shield") {
                Text("Access and formulae ForgedBrew needs so topgrade can run all of its update functions and tasks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                fullDiskAccessRow
                Divider()
                masRow
                Divider()
                topgradeRow
            }

            // ===== Updates section =====
            sectionHeader("Updates")

            // App-level updates: ForgedBrew updating itself via Sparkle. This is
            // what most people expect an "Updates" tab to mean, so it goes first.
            SettingsCard(title: "ForgedBrew updates", systemImage: "arrow.down.app") {
                Text("Keep the ForgedBrew app itself up to date. ForgedBrew also checks automatically in the background.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Check for ForgedBrew Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                // This stays disabled until the self-update release pipeline is
                // live. `updater.canCheckForUpdates` is false until the Sparkle
                // SUFeedURL in Info.plist points at a published appcast.xml feed.
                // This is NOT a code bug
                // in the button — clicking it "fails" only because there's
                // nothing to check against.
                //
                // Auto-update activates once a signed build and an appcast.xml
                // feed are published and the SUFeedURL points at it. Once the feed
                // is live, `canCheckForUpdates` flips to true and this button works
                // with no further changes here.
                .disabled(!updater.canCheckForUpdates)

                // User-facing explanation for why the button is currently
                // inactive, so it doesn't look broken. Shown only while
                // self-update isn't available yet.
                if !updater.canCheckForUpdates {
                    Label {
                        Text("Self-update isn’t available in this build yet. It turns on automatically once the first signed release is published. For now, update ForgedBrew by installing the latest build manually.")
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                }

                Divider()
                    .padding(.vertical, 2)

                // Automatic self-update preferences. These write straight through
                // to Sparkle (SPUUpdater) and persist across launches.
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Check for updates automatically")
                            .font(.system(size: 13, weight: .medium))
                        Text("Let ForgedBrew check for new versions of itself on a regular schedule in the background.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Color(red: 0.20, green: 0.55, blue: 0.34))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Download updates automatically")
                            .font(.system(size: 13, weight: .medium))
                        Text("Download new versions in the background and install them the next time you launch ForgedBrew.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $updater.automaticallyDownloadsUpdates)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Color(red: 0.20, green: 0.55, blue: 0.34))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!updater.automaticallyChecksForUpdates)

                if let last = updater.lastUpdateCheckDate {
                    Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                // Homebrew hint: if the user installed ForgedBrew via a cask, the
                // in-app updater can be turned off and brew upgrade used instead.
                Label {
                    Text("Installed ForgedBrew with Homebrew? You can turn these off and update with brew upgrade forgedbrew instead.")
                } icon: {
                    Image(systemName: "mug")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }

            // Package-level updates: how ForgedBrew DETECTS updates for your
            // installed apps via Homebrew. Relabeled so it's clearly about
            // which apps ForgedBrew checks, not about updating ForgedBrew.
            SettingsCard(title: "Self-updating apps", systemImage: "shippingbox") {
                Toggle(isOn: $includeSelfUpdatingApps) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Check apps that update themselves")
                            .font(.system(size: 13, weight: .medium))
                        Text("Some apps — like Microsoft Office, Google Chrome, and Claude — update themselves in the background, so Homebrew normally leaves them off the update list. Turn this on and ForgedBrew will check those apps too and let you update them through Homebrew. You may see them listed even when they’re already current; updating them simply reinstalls the latest version.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(Color(red: 0.20, green: 0.55, blue: 0.34))
                // Re-check the outdated list immediately so the badge + Updates
                // screen reflect the new setting without a manual refresh.
                .onChange(of: includeSelfUpdatingApps) { _, _ in
                    Task { await appData.refreshInstalled() }
                }
            }

            // Background update checks: keep the available-update counts fresh on
            // a timer while ForgedBrew is running — including when it lives only in
            // the menu bar — so the badge stays current and the user can be
            // notified when new updates appear, without opening the app.
            SettingsCard(title: "Background update checks", systemImage: "clock.arrow.circlepath") {
                Toggle(isOn: $startup.backgroundRefreshEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Check for updates in the background")
                            .font(.system(size: 13, weight: .medium))
                        Text("While ForgedBrew is running — even when it is only in the menu bar — it quietly re-checks for app and Homebrew updates on a schedule and keeps the menu bar and Dock counts up to date.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(Color(red: 0.20, green: 0.55, blue: 0.34))

                if startup.backgroundRefreshEnabled {
                    Divider()

                    HStack {
                        Text("Check every")
                            .font(.system(size: 13))
                        Spacer()
                        Picker("Check every", selection: $startup.backgroundRefreshHours) {
                            ForEach(StartupSettings.backgroundRefreshChoices, id: \.self) { hours in
                                Text(Self.intervalLabel(hours)).tag(hours)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }

                    Divider()

                    Toggle(isOn: $startup.notifyOnNewUpdates) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Notify me when new updates are found")
                                .font(.system(size: 13, weight: .medium))
                            Text("Posts a macOS notification when a background check discovers newly available updates. You can manage ForgedBrew notifications anytime in System Settings \u{25B8} Notifications.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color(red: 0.20, green: 0.55, blue: 0.34))
                }

                Divider()

                // Guidance: background checks only persist across reboots if the
                // app actually relaunches at login. With "Show in menu bar" on, a
                // login launch is silent — menu-bar icon only, no Dock icon.
                Label {
                    Text("For checks to keep running after you restart your Mac, also turn on Load on startup and Show in menu bar (above). ForgedBrew will run quietly in the menu bar with no Dock icon.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Re-sync the Launch-at-login toggle with the real system state each
        // time the pane appears, in case the user changed the login item in
        // System Settings while ForgedBrew was running. Also refresh the system
        // access statuses (FDA + mas) for the same reason.
        .onAppear {
            startup.refreshFromSystem()
            refreshSystemAccess()
        }
    }

    // Re-probe Full Disk Access and the mas CLI. Cheap (a directory read and a
    // couple of file-exists checks), so safe to call on every appearance.
    // Friendly label for a background-check interval in hours.
    static func intervalLabel(_ hours: Int) -> String {
        switch hours {
        case 1:  return "Every hour"
        case 24: return "Once a day"
        default: return "Every \(hours) hours"
        }
    }

    private func refreshSystemAccess() {
        fdaGranted = FullDiskAccess.isGranted()
        masInstalled = AppUpdateService.locateMas() != nil
        topgradeInstalled = TopgradeService.isInstalled
    }

    // MARK: - System access rows

    // Full Disk Access status, mirroring the Maintenance banner: green check +
    // "granted" when allowed, otherwise an orange prompt with a jump to the
    // Privacy pane in System Settings.
    private var fullDiskAccessRow: some View {
        HStack(spacing: 12) {
            Image(systemName: fdaGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(fdaGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(fdaGranted ? "Full Disk Access granted" : "Full Disk Access needed")
                    .font(.system(size: 13, weight: fdaGranted ? .medium : .semibold))
                Text(fdaGranted
                     ? "macOS is letting ForgedBrew read your library, so cleanup and cache sizes are accurate."
                     : "ForgedBrew needs Full Disk Access to clean Homebrew\u{2019}s cache and show accurate cleanup numbers. Grant it in System Settings, then reopen ForgedBrew.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !fdaGranted {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help(Text(verbatim: "Open System Settings \u{25B8} Privacy & Security \u{25B8} Full Disk Access"))
            }
        }
        .padding(10)
        .background(fdaGranted ? AnyShapeStyle(Color.green.opacity(0.08)) : AnyShapeStyle(Color.orange.opacity(0.10)),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    // mas (Mac App Store CLI) status: green "installed" when present, otherwise
    // an inline "Install mas" button that runs `brew install mas` (same path as
    // the Mac Store/Other Apps screen) so App Store update versions can be read.
    private var masRow: some View {
        HStack(spacing: 12) {
            Image(systemName: masInstalled ? "checkmark.circle.fill" : "app.badge")
                .font(.system(size: 16))
                .foregroundStyle(masInstalled ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(masInstalled ? "Mac App Store CLI (mas) installed" : "Mac App Store CLI (mas) not installed")
                    .font(.system(size: 13, weight: masInstalled ? .medium : .semibold))
                Text(masInstalled
                     ? "ForgedBrew can read available versions for your Mac App Store apps."
                     : "Install the mas command-line tool so ForgedBrew can detect Mac App Store update versions. Optional \u{2014} App Store apps still open in the App Store for updating without it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !masInstalled {
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
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(installingMas)
                .help(Text(verbatim: "Runs `brew install mas` so ForgedBrew can read Mac App Store update versions"))
            }
        }
        .padding(10)
        .background(masInstalled ? AnyShapeStyle(Color.green.opacity(0.08)) : AnyShapeStyle(Color.orange.opacity(0.10)),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    // Installs the `mas` CLI via Homebrew, then re-probes so the row flips to
    // the green "installed" state. Mirrors the Mac Store/Other Apps screen.
    private func installMas() {
        guard !installingMas else { return }
        installingMas = true
        Task {
            for await _ in appData.installFormula("mas") {}
            refreshSystemAccess()
            installingMas = false
        }
    }

    // topgrade CLI status: green "installed" when present, otherwise an inline
    // "Install topgrade" button that runs `brew install topgrade`. topgrade is
    // what powers the in-place "Update" and "Update All Apps" actions on the
    // Mac Store/Other Apps screen, so this mirrors the mas row right above it.
    private var topgradeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: topgradeInstalled ? "checkmark.circle.fill" : "arrow.up.circle")
                .font(.system(size: 16))
                .foregroundStyle(topgradeInstalled ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(topgradeInstalled ? "topgrade installed" : "topgrade not installed")
                    .font(.system(size: 13, weight: topgradeInstalled ? .medium : .semibold))
                Text(topgradeInstalled
                     ? "ForgedBrew can update your Mac App Store, Sparkle, and Homebrew-cask apps in place from the Mac Store/Other Apps screen."
                     : "Install the topgrade tool so ForgedBrew can update apps in place from the Mac Store/Other Apps screen. Optional \u{2014} without it you can still open each app\u{2019}s website to update manually.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !topgradeInstalled {
                Button {
                    installTopgrade()
                } label: {
                    HStack(spacing: 6) {
                        if installingTopgrade {
                            ProgressView().controlSize(.small)
                            Text("Installing topgrade\u{2026}")
                        } else {
                            Image(systemName: "arrow.down.circle")
                            Text("Install topgrade")
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(installingTopgrade)
                .help(Text(verbatim: "Runs `brew install topgrade` so ForgedBrew can update apps in place"))
            }
        }
        .padding(10)
        .background(topgradeInstalled ? AnyShapeStyle(Color.green.opacity(0.08)) : AnyShapeStyle(Color.orange.opacity(0.10)),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    // Installs the `topgrade` CLI via Homebrew, then re-probes so the row flips
    // to the green "installed" state. Mirrors the mas install path above.
    private func installTopgrade() {
        guard !installingTopgrade else { return }
        installingTopgrade = true
        Task {
            for await _ in appData.installFormula("topgrade") {}
            refreshSystemAccess()
            installingTopgrade = false
        }
    }

    // A lightweight section divider/title used to separate the merged tab's two
    // halves without changing the look of the cards themselves.
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .padding(.leading, 2)
            .padding(.top, 2)
    }

    // Startup permissions status + jump to System Settings, mirroring the Full
    // Disk Access banner on the Maintenance screen. "Load on startup" relies on
    // macOS having ForgedBrew's login item enabled; if it was disabled in System
    // Settings ▸ General ▸ Login Items, "Load on startup" silently won't work.
    // This row shows the current state and offers a one-click jump to fix it.
    private var startupPermissionsRow: some View {
        let enabled = startup.launchAtLogin
        return HStack(spacing: 12) {
            Image(systemName: enabled ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(enabled ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(enabled ? "Startup permission granted" : "Startup permission needed")
                    .font(.system(size: 13, weight: enabled ? .medium : .semibold))
                Text(enabled
                     ? "macOS is allowing ForgedBrew to open at login."
                     : "macOS hasn\u{2019}t enabled ForgedBrew\u{2019}s login item yet. Turn on \u{201C}Load on startup\u{201D} above, then enable ForgedBrew under Login Items in System Settings if prompted.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            startupPermissionButton(enabled: enabled)
        }
        .padding(10)
        .background(enabled ? AnyShapeStyle(Color.green.opacity(0.08)) : AnyShapeStyle(Color.orange.opacity(0.10)),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    // Split out so the button style is a single concrete type per branch — a
    // ternary across `.bordered` and `.borderedProminent` can't be type-checked
    // because they're different ButtonStyle structs.
    @ViewBuilder
    private func startupPermissionButton(enabled: Bool) -> some View {
        let action = {
            openLoginItemsSettings()
            // Re-check after the user returns from System Settings.
            startup.refreshFromSystem()
        }
        if enabled {
            Button("Enable permissions in System", action: action)
                .controlSize(.small)
                .buttonStyle(OutlinedButtonStyle())
                .help(Text(verbatim: "Open System Settings ▸ General ▸ Login Items to enable ForgedBrew at startup"))
        } else {
            Button("Enable permissions in System", action: action)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help(Text(verbatim: "Open System Settings ▸ General ▸ Login Items to enable ForgedBrew at startup"))
        }
    }

    // Opens the Login Items pane in System Settings (falls back to the General
    // pane / app's settings root on older macOS where the deep link differs).
    private func openLoginItemsSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.users"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func appearanceButton(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .selectionChip(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App Locations (standard + custom folders)
//
// Keeps the two standard toggles (Applications / My Applications) exactly as
// before, then adds a user-managed list of extra folders to scan, for people
// who install apps somewhere unusual. The custom list persists to the on-disk
// config (~/.config/forgedbrew/config.json) via ForgedBrewConfig so it survives app
// upgrades and reboots — see AppLocationSettings, which folds these folders
// into every scan.

private struct AppLocationsSettingsTab: View {
    @AppStorage(AppLocationSettings.scanSystemApplicationsKey) private var scanSystemApps: Bool = true
    @AppStorage(AppLocationSettings.scanUserApplicationsKey) private var scanUserApps: Bool = true

    // Live, in-memory copy of the custom folders, loaded from disk on appear and
    // written back whenever it changes.
    @State private var customLocations: [String] = []
    @State private var feedback: String? = nil

    private var atLimit: Bool { customLocations.count >= AppLocationSettings.maxCustomLocations }

    var body: some View {
        SettingsTabScaffold {
            // --- Standard locations (unchanged behavior) ---
            SettingsCard(title: "App scan locations", systemImage: "folder") {
                Text("Choose where ForgedBrew looks for installed apps when scanning (for adopting apps into Homebrew, removing quarantine, and measuring sizes). Most apps live in the main Applications folder, but some are installed just for your user account.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $scanSystemApps) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Applications (all users)")
                                .font(.system(size: 13, weight: .medium))
                            Text(AppLocationSettings.systemApplicationsPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color(red: 0.20, green: 0.55, blue: 0.34))

                    Toggle(isOn: $scanUserApps) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("My Applications (this user only)")
                                .font(.system(size: 13, weight: .medium))
                            Text(AppLocationSettings.userApplicationsPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color(red: 0.20, green: 0.55, blue: 0.34))
                }

                if !scanSystemApps && !scanUserApps && customLocations.isEmpty {
                    Text("Both standard locations are off and you haven’t added any custom folders, so ForgedBrew will fall back to scanning the main Applications folder.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // --- Custom locations (new) ---
            SettingsCard(title: "Custom folders", systemImage: "folder.badge.plus") {
                Text("Add other folders where you keep apps — for example a “Tools” folder, an external drive, or a developer apps folder. ForgedBrew scans these alongside the locations above. Your list is saved on this Mac (~/.config/forgedbrew/config.json) so it sticks around through updates and restarts.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if customLocations.isEmpty {
                    Text("No custom folders yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(customLocations.enumerated()), id: \.offset) { index, path in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    removeLocation(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(Text(verbatim: "Remove this folder"))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        addLocation()
                    } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .controlSize(.regular)
                    .disabled(atLimit)

                    Text("\(customLocations.count) of \(AppLocationSettings.maxCustomLocations) used")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
                .padding(.top, 2)

                if atLimit {
                    Text("You’ve reached the maximum of \(AppLocationSettings.maxCustomLocations) custom folders. Remove one to add another.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let feedback {
                    Text(feedback)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
        }
        .onAppear {
            customLocations = ForgedBrewConfig.load().customAppLocations
        }
    }

    // Presents an NSOpenPanel limited to a single directory, then appends the
    // chosen folder (rejecting blanks, duplicates, and over-limit additions) and
    // persists immediately.
    private func addLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder where ForgedBrew should also look for installed apps."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path

        guard !customLocations.contains(path) else {
            flash("That folder is already in the list.")
            return
        }
        guard customLocations.count < AppLocationSettings.maxCustomLocations else { return }

        customLocations.append(path)
        persist("Folder added.")
    }

    private func removeLocation(at index: Int) {
        guard customLocations.indices.contains(index) else { return }
        customLocations.remove(at: index)
        persist("Folder removed.")
    }

    private func persist(_ message: String) {
        if ForgedBrewConfig.saveCustomAppLocations(customLocations) {
            flash(message)
        } else {
            flash("Could not save the folder list.")
        }
    }

    private func flash(_ message: String) {
        feedback = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            feedback = nil
        }
    }
}

// MARK: - APIs (optional SerpApi image-search key)

private struct APIsSettingsTab: View {
    // The key the user types. Loaded from the on-disk config on appear.
    @State private var keyField: String = ""
    // Whether a key is currently saved on disk (drives the status pill).
    @State private var hasSavedKey: Bool = false
    // Transient "Saved" / "Removed" confirmation feedback.
    @State private var feedback: String? = nil

    private let signupURL = URL(string: "https://serpapi.com/users/sign_up")!
    private let keyDashboardURL = URL(string: "https://serpapi.com/manage-api-key")!

    var body: some View {
        SettingsTabScaffold {
            imageSearchCard
        }
        .onAppear {
            keyField = ForgedBrewConfig.load().serpApiKey ?? ""
            hasSavedKey = !keyField.isEmpty
        }
    }

    private var imageSearchCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title + status pill.
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Screenshot image search")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                statusPill
            }

            Text("ForgedBrew shows app screenshots from each app’s GitHub README and its repository’s preview image. This works with no setup. If you add a personal SerpApi key, ForgedBrew will also search the web for screenshots of apps that don’t publish one on GitHub.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Key entry + actions.
            VStack(alignment: .leading, spacing: 8) {
                Text("SerpApi key")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) {
                    SecureField("Paste your SerpApi key", text: $keyField)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove") { remove() }
                        .controlSize(.regular)
                        .disabled(!hasSavedKey)
                }
                if let feedback {
                    Text(feedback)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }
            }

            Divider()

            // How-to.
            VStack(alignment: .leading, spacing: 6) {
                Text("How to get a free key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Label {
                    Text("Create a free SerpApi account (250 searches/month, no card required).")
                } icon: {
                    Text("1.").font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .font(.system(size: 12))
                Label {
                    Text("Copy your private API key from the dashboard.")
                } icon: {
                    Text("2.").font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .font(.system(size: 12))
                Label {
                    Text("Paste it above and click Save. No restart needed.")
                } icon: {
                    Text("3.").font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .font(.system(size: 12))

                HStack(spacing: 14) {
                    Link("Create a free account", destination: signupURL)
                    Link("Open API key dashboard", destination: keyDashboardURL)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 2)

                Text("Your key is stored only on this Mac (~/.config/forgedbrew/config.json) and is never bundled with the app or shared.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cardStroke(cornerRadius: 12)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(hasSavedKey ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(hasSavedKey ? "Key configured" : "No key (optional)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.10))
        .clipShape(Capsule())
        .pillStroke()
    }

    private func save() {
        let trimmed = keyField.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if ForgedBrewConfig.saveSerpApiKey(trimmed) {
            hasSavedKey = true
            flash("Saved. Image search is now enabled.")
        } else {
            flash("Could not write the config file.")
        }
    }

    private func remove() {
        if ForgedBrewConfig.saveSerpApiKey(nil) {
            keyField = ""
            hasSavedKey = false
            flash("Removed. ForgedBrew will use GitHub screenshots only.")
        }
    }

    private func flash(_ message: String) {
        feedback = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            feedback = nil
        }
    }
}

// MARK: - About (license, creator, donate, and User Manual)

private struct AboutSettingsTab: View {
    @Environment(AppDataService.self) private var appData
    // Opens the standalone, scrollable User Manual window (see UserManualWindowID
    // and the Window scene in ForgedBrewApp). Lets users read the full manual —
    // with screenshots and how-tos — without leaving the app for GitHub.
    @Environment(\.openWindow) private var openWindow

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    // ForgedBrew's PayPal donation page ("ForgedBrew App Donation" hosted button).
    // Clicking Donate opens this in the browser.
    private let donateURL = URL(string: "https://www.paypal.com/ncp/payment/KFEQXCGU4UGKC")!

    var body: some View {
        SettingsTabScaffold {
            SettingsCard(title: "About ForgedBrew", systemImage: "info.circle") {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ForgedBrew")
                            .font(.system(size: 16, weight: .semibold))
                        Text("A friendly GUI for Homebrew.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Created by Highfield-London")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Link("www.forgedbrew.com", destination: URL(string: "https://www.forgedbrew.com")!)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Text("Version \(appVersion)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(appData.homebrewVersion.isEmpty ? "Homebrew: detecting…" : "Homebrew: \(appData.homebrewVersion)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text("Apache License 2.0")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                Text("Use ForgedBrew ▸ Check for Updates… from the menu bar to update the app itself. Package and app updates live in the Updates section of the sidebar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Privacy — make the no-data promise explicit and prominent. ForgedBrew
            // has no analytics, no telemetry, and no remote backend of its own.
            SettingsCard(title: "Privacy", systemImage: "lock.shield") {
                Text("Completely private. ForgedBrew runs entirely on your Mac. It collects no data, has no analytics or tracking, and nothing about you or your apps is ever sent off your computer. The only network requests are to Homebrew and the Mac App Store to check for and download app updates — exactly what you ask for, nothing more.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // User Manual — opens an in-app, scrollable manual window so users
            // never have to hunt for a README on GitHub.
            SettingsCard(title: "User manual", systemImage: "book") {
                Text("New to ForgedBrew or want the full tour? Open the built-in user manual — a complete, scrollable guide to every part of the app, with how-tos for installing, updating, maintenance, tags & notes, and parking. It opens right here in the app.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    openWindow(id: UserManualWindowID)
                } label: {
                    Label("Open User Manual", systemImage: "book.pages")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            // Free + donations. No license keys, no trial — ForgedBrew is free to
            // use; the Donate button is an optional way to support development.
            SettingsCard(title: "Support ForgedBrew", systemImage: "heart") {
                Text("ForgedBrew is free and open. Support continued development with an optional donation — it’s genuinely appreciated, and never required.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: donateURL) {
                    Label("Donate", systemImage: "heart.fill")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.pink.opacity(0.15))
                        .foregroundStyle(.pink)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppDataService.shared)
        .environment(Updater())
        .frame(width: 620, height: 560)
}
