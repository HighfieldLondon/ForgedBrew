import SwiftUI
import ServiceManagement
import AppKit

// MARK: - Startup, Dock & Menu Bar behavior
//
// Backs the toggles in Settings ▸ General ▸ Startup. The model is deliberately
// just three independent switches — no separate "start hidden" option:
//
//   • Load on startup  — registers the app as a macOS login item (SMAppService).
//   • Show in menu bar — adds an NSStatusItem (menu bar extra) whose icon
//     carries the available-update count. Left-click opens a popover listing
//     what's outdated, with Update buttons (MenuBarPopoverView); right-click
//     drops a compact Open / Refresh / Quit menu. When ON, a login launch
//     starts FORGEDBREW HIDDEN in the menu bar (no window, no Dock bounce) —
//     i.e. "show in menu bar" implies start-hidden.
//   • Keep in Dock     — when ON, the Dock icon is shown permanently. When OFF,
//     there's no Dock icon while the app sits in the menu bar; opening the
//     window from the menu bar shows a TEMPORARY Dock icon for as long as the
//     window is open, then it disappears again when the window closes.
//
// Also owns the DOCK BADGE: the number of available updates (Homebrew +
// Mac/other apps, parked excluded) shown on the Dock icon — like Messages'
// unread count. The badge shows whenever a Dock icon exists (permanent, or the
// temporary one while a window is open). Call updateBadge(count:) on changes.

/// The colour of the menu bar mug. Backs the Appearance section in the menu bar
/// popover.
///
/// `monochrome` is the odd one out and worth understanding before you touch the
/// rendering: it's the only style drawn as a TEMPLATE image, which is what lets
/// macOS tint it automatically — dark in a light menu bar, light in a dark one,
/// dimmed on an inactive display. The coloured styles can't do that (a template
/// image is a mask; it has no colours to keep), so they're composed as ordinary
/// images and look the same everywhere. That's the trade, and it's why
/// monochrome is the only one that ever truly matches the rest of your menu bar.
nonisolated enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case amber
    case monochrome
    case blue
    case green
    case red
    case purple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .amber:      return "Amber"
        case .monochrome: return "Monochrome"
        case .blue:       return "Blue"
        case .green:      return "Green"
        case .red:        return "Red"
        case .purple:     return "Purple"
        }
    }

    /// The mug's fill. nil for `monochrome`, which is drawn as a template image
    /// and takes its colour from the system instead.
    var tint: NSColor? {
        switch self {
        case .monochrome: return nil
        // The original beer-amber, kept exactly as it was so existing users see
        // no change on upgrade.
        case .amber:  return NSColor(calibratedRed: 0.83, green: 0.55, blue: 0.10, alpha: 1.0)
        // Deliberately a touch deeper / less saturated than the system colours,
        // matching ActionColors' reasoning: a menu bar icon sits next to system
        // glyphs all day and shouldn't glare.
        case .blue:   return NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.90, alpha: 1.0)
        case .green:  return NSColor(calibratedRed: 0.22, green: 0.62, blue: 0.36, alpha: 1.0)
        case .red:    return NSColor(calibratedRed: 0.80, green: 0.28, blue: 0.26, alpha: 1.0)
        case .purple: return NSColor(calibratedRed: 0.53, green: 0.38, blue: 0.82, alpha: 1.0)
        }
    }

    /// The SwiftUI mirror of `tint`, for the swatches in the Appearance section.
    /// Monochrome shows as the current label colour so the swatch previews what
    /// the user will actually get.
    var swatch: Color {
        guard let tint else { return Color(nsColor: .labelColor) }
        return Color(nsColor: tint)
    }
}

/// Single source of truth for ForgedBrew's startup / presentation behaviour:
/// login-item registration, Dock-icon policy, the menu-bar extra, the Dock and
/// menu-bar update badges, and the headless (menu-bar-only) launch mode. A
/// @MainActor @Observable singleton (`shared`) so SwiftUI toggles bind straight
/// to it and AppKit lifecycle code reads the same live state.
@MainActor
@Observable
final class StartupSettings {
    static let shared = StartupSettings()

    // Persisted preferences.
    static let keepInDockKey = "forgedbrewKeepInDock"
    static let showInMenuBarKey = "forgedbrewShowInMenuBar"
    static let menuBarIconStyleKey = "forgedbrewMenuBarIconStyle"
    // Background update-check preferences (see BackgroundRefreshCoordinator).
    static let backgroundRefreshEnabledKey = "forgedbrewBackgroundRefreshEnabled"
    static let backgroundRefreshHoursKey = "forgedbrewBackgroundRefreshHours"
    static let notifyOnNewUpdatesKey = "forgedbrewNotifyOnNewUpdates"

    // Allowed background-check intervals (hours), surfaced in the Settings picker.
    static let backgroundRefreshChoices: [Int] = [3, 6, 12, 24]
    static let defaultBackgroundRefreshHours = 3

    // Mirrors the login-item registration state.
    var launchAtLogin: Bool = false {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    // Mirrors the Dock-visibility preference and applies it live.
    var keepInDock: Bool = true {
        didSet {
            guard keepInDock != oldValue else { return }
            UserDefaults.standard.set(keepInDock, forKey: Self.keepInDockKey)
            // Don't fight the temporary Dock icon while a window is open; the
            // window-open path manages activation policy in that case.
            if !isWindowVisible {
                Self.applyDockVisibility(keepInDock)
            }
        }
    }

    // The menu bar mug's colour. Re-renders the live icon on change, so the
    // Appearance swatches update the real menu bar as the user clicks them.
    var menuBarIconStyle: MenuBarIconStyle = .amber {
        didSet {
            guard menuBarIconStyle != oldValue else { return }
            UserDefaults.standard.set(menuBarIconStyle.rawValue, forKey: Self.menuBarIconStyleKey)
            applyStatusItemBadge(lastUpdateCount)
        }
    }

    // Mirrors the menu-bar-extra preference and applies it live.
    var showInMenuBar: Bool = false {
        didSet {
            guard showInMenuBar != oldValue else { return }
            UserDefaults.standard.set(showInMenuBar, forKey: Self.showInMenuBarKey)
            applyMenuBarVisibility(showInMenuBar)
        }
    }

    // Whether ForgedBrew quietly re-checks for updates on a timer while it is
    // running (including menu-bar-only / headless mode). Backs the Settings
    // toggle. Changing it (re)starts or stops BackgroundRefreshCoordinator via
    // backgroundRefreshDidChange.
    var backgroundRefreshEnabled: Bool = true {
        didSet {
            guard backgroundRefreshEnabled != oldValue else { return }
            UserDefaults.standard.set(backgroundRefreshEnabled, forKey: Self.backgroundRefreshEnabledKey)
            backgroundRefreshDidChange?()
        }
    }

    // How often (in hours) the background check runs. Backs the Settings picker.
    var backgroundRefreshHours: Int = StartupSettings.defaultBackgroundRefreshHours {
        didSet {
            guard backgroundRefreshHours != oldValue else { return }
            UserDefaults.standard.set(backgroundRefreshHours, forKey: Self.backgroundRefreshHoursKey)
            backgroundRefreshDidChange?()
        }
    }

    // Whether a macOS notification is posted when a background check finds NEW
    // updates (i.e. the count went up since the last check). Backs a toggle.
    var notifyOnNewUpdates: Bool = true {
        didSet {
            guard notifyOnNewUpdates != oldValue else { return }
            UserDefaults.standard.set(notifyOnNewUpdates, forKey: Self.notifyOnNewUpdatesKey)
        }
    }

    // Set by BackgroundRefreshCoordinator so changes to the prefs above can
    // restart its timer live, without StartupSettings importing the coordinator.
    var backgroundRefreshDidChange: (() -> Void)?

    // Set by the root scene at launch: asks SwiftUI to build/show the main
    // window (openWindow(id: MainWindowID)). The AppKit side — this class, the
    // AppDelegate, StatusItemTarget — lives outside the SwiftUI environment and
    // cannot reach @Environment(\.openWindow), so the scene hands the action
    // down. Without it, AppKit can only order EXISTING windows front, which is
    // no help once the WindowGroup window has been destroyed.
    var openMainWindow: (() -> Void)?

    // Set by the AppDelegate at launch when this run is a login-item launch and
    // showInMenuBar is on. While true the app is living in the menu bar with no
    // window; closing the (never-shown) window must NOT quit the app.
    var isRunningHeadless: Bool = false

    // True once the user has EXPLICITLY asked to quit (Cmd+Q or the menu bar
    // "Quit ForgedBrew"). applicationShouldTerminate uses this to distinguish a
    // real quit (terminate) from a last-window-closed terminate (which, when the
    // menu bar is on, we cancel so the app keeps living in the menu bar).
    var userRequestedQuit: Bool = false

    // True once Sparkle is about to relaunch the app to install a downloaded
    // update. Like userRequestedQuit, this lets applicationShouldTerminate allow
    // a real termination even when the app would otherwise stay resident in the
    // menu bar — without it, Sparkle's quit gets cancelled by the keep-alive rule
    // and the install stalls until the user force-quits.
    var isInstallingUpdate: Bool = false

    // Marks an explicit user quit and then terminates. Call from the menu bar
    // "Quit" item and the app's Cmd+Q command so the quit isn't cancelled by
    // applicationShouldTerminate's keep-alive rule.
    func requestQuit() {
        userRequestedQuit = true
        NSApp.terminate(nil)
    }

    // True while a real window is on screen. Drives the temporary-Dock-icon
    // behavior when Keep in Dock is off.
    private var isWindowVisible: Bool = false

    // The most recent available-update total, so newly-created surfaces (the
    // status item, or the Dock badge after a policy change) can re-render the
    // current number without waiting for the next refresh.
    private(set) var lastUpdateCount: Int = 0

    // The live menu bar extra, when enabled.
    private var statusItem: NSStatusItem?

    // The popover shown by a left-click on the menu bar icon (MenuBarPopoverView).
    // Built lazily on first click and kept for the life of the status item, so
    // reopening it is instant and the SwiftUI tree isn't rebuilt each time.
    private var popover: NSPopover?

    // True while a menu bar extra is actually installed. Used as a belt-and-
    // suspenders guard so the app never quits out from under a live menu bar
    // icon, even if the showInMenuBar bool and the real status item ever drift.
    var hasStatusItem: Bool { statusItem != nil }

    private init() {
        // Seed from the real system state on creation.
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        keepInDock = UserDefaults.standard.object(forKey: Self.keepInDockKey) as? Bool ?? true
        // MUST be seeded BEFORE showInMenuBar: that property's didSet installs
        // the status item and renders the icon, so the colour has to be known by
        // then — otherwise the menu bar flashes amber before correcting itself.
        // Falls back to amber (the historical colour) when unset or when the
        // stored value isn't a style we still ship — never trust the raw string.
        menuBarIconStyle = (UserDefaults.standard.object(forKey: Self.menuBarIconStyleKey) as? String)
            .flatMap(MenuBarIconStyle.init(rawValue:)) ?? .amber
        showInMenuBar = UserDefaults.standard.object(forKey: Self.showInMenuBarKey) as? Bool ?? false
        backgroundRefreshEnabled = UserDefaults.standard.object(forKey: Self.backgroundRefreshEnabledKey) as? Bool ?? true
        let savedHours = UserDefaults.standard.object(forKey: Self.backgroundRefreshHoursKey) as? Int
        backgroundRefreshHours = Self.backgroundRefreshChoices.contains(savedHours ?? 0)
            ? (savedHours ?? Self.defaultBackgroundRefreshHours)
            : Self.defaultBackgroundRefreshHours
        notifyOnNewUpdates = UserDefaults.standard.object(forKey: Self.notifyOnNewUpdatesKey) as? Bool ?? true
    }

    // Re-reads the live login-item status (call when the Settings pane appears).
    // The user may have toggled ForgedBrew's login item directly in System
    // Settings while the app was running, so the in-memory mirror can be stale.
    // _suppressApply is raised around the write so adopting the system's value
    // does NOT loop back through applyLaunchAtLogin and re-register/unregister.
    func refreshFromSystem() {
        let enabled = (SMAppService.mainApp.status == .enabled)
        if enabled != launchAtLogin {
            _suppressApply = true
            launchAtLogin = enabled
            _suppressApply = false
        }
    }

    // Guards launchAtLogin's didSet: true while we're syncing the property FROM
    // the system, so those writes don't trigger an SMAppService register call.
    private var _suppressApply = false

    // Registers/unregisters the login item to match the toggle. On failure we
    // roll the published value back to whatever the system actually reports
    // (again under _suppressApply) so the UI never shows a state SMAppService
    // didn't accept — e.g. when the user has denied login items system-wide.
    private func applyLaunchAtLogin(_ enable: Bool) {
        guard !_suppressApply else { return }
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            _suppressApply = true
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            _suppressApply = false
        }
    }

    // MARK: - Headless (start-hidden) launch

    // On a login-item launch, start hidden whenever the menu bar is on — the
    // menu bar icon is the way back to the window, so it's a safe place to hide.
    var shouldStartHeadless: Bool {
        showInMenuBar
    }

    // Enter menu-bar-only headless mode at launch: hide from the Dock, make sure
    // the menu bar extra exists (the user's lifeline back to the window), and
    // hide any window SwiftUI created so nothing flashes on screen. The app
    // keeps running because isRunningHeadless suppresses quit-on-last-window.
    func enterHeadlessMode() {
        isRunningHeadless = true
        isWindowVisible = false
        installStatusItemIfNeeded()
        applyStatusItemBadge(lastUpdateCount)
        // Menu-bar-only: no Dock icon, no activation.
        NSApp.setActivationPolicy(.accessory)
        // Hide (don't close) the auto-created window so the menu bar can simply
        // re-show it, and so applicationShouldTerminateAfterLastWindowClosed
        // (a closed last window) doesn't quit us.
        for window in NSApp.windows where window.canBecomeMain {
            window.orderOut(nil)
        }
    }

    // MARK: - Showing the main window

    /// The single way back to the main window from anywhere in the AppKit layer
    /// (menu bar "Open ForgedBrew", Dock-icon reopen).
    ///
    /// This used to be `NSApp.windows.first(where: { $0.canBecomeMain })` +
    /// `makeKeyAndOrderFront`, followed by an UNCONDITIONAL
    /// `windowDidBecomeVisible()`. Two bugs fell out of that:
    ///
    ///   • The predicate matched auxiliary windows (Settings, Welcome, the User
    ///     Manual all report canBecomeMain), and NSApp.windows has no defined
    ///     order — so it could raise Settings and call it a day.
    ///   • windowDidBecomeVisible() ran even when NOTHING was shown. It flips
    ///     the activation policy to .regular and activates, which is precisely
    ///     the "Dock icon lights up but no window appears" symptom.
    ///
    /// So: find a REAL main window (auxiliaries excluded) and re-show it; if
    /// none exists — a WindowGroup window is destroyed, not hidden, by
    /// performClose (Cmd+W, or the red X while an auxiliary window was open) —
    /// ask SwiftUI to build a fresh one. Only report the window visible once one
    /// genuinely is.
    func showMainWindow() {
        if let window = mainWindow() {
            window.makeKeyAndOrderFront(nil)
            windowDidBecomeVisible()
            return
        }
        // No main window object left. Rebuild it via the scene bridge, and only
        // then take credit for it — openWindow is async in effect, so we hand
        // windowDidBecomeVisible() the next runloop pass once AppKit has
        // actually materialized the window.
        guard let openMainWindow else {
            // The bridge is only nil before the root scene's .task has run — i.e.
            // so early that SwiftUI is about to show the window itself anyway.
            return
        }
        // .regular first: SwiftUI will not place a new window for an .accessory
        // app the way the user expects, and we're definitely showing one now.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        openMainWindow()
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            // Let SwiftUI create the window, then adopt it properly (Dock icon,
            // badge, headless exit). If it still didn't appear, do nothing —
            // better a no-op than a lit Dock with no window behind it.
            if let window = mainWindow() {
                window.makeKeyAndOrderFront(nil)
                windowDidBecomeVisible()
            }
        }
    }

    /// The app's real main window, if one exists: a window that can become main
    /// and isn't one of the auxiliary scenes (Settings / Welcome / User Manual).
    /// Prefers a visible one, then falls back to a hidden-but-alive window (the
    /// menu-bar "hide, don't close" path leaves exactly that).
    private func mainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter {
            $0.canBecomeMain && !AppDelegate.isAuxiliaryWindow($0)
        }
        return candidates.first(where: { $0.isVisible }) ?? candidates.first
    }

    // MARK: - Window open / close (drives the temporary Dock icon)

    // Called when a ForgedBrew window becomes visible (opened from the menu bar,
    // Dock, or normal launch). Leaves headless mode and — if Keep in Dock is
    // off — shows a TEMPORARY Dock icon for the lifetime of the window so the
    // update badge has somewhere to live and the app behaves like a normal app.
    func windowDidBecomeVisible() {
        isRunningHeadless = false
        isWindowVisible = true
        // Any open window means a Dock icon (.regular), regardless of the Keep
        // in Dock preference — that's the temporary icon when Dock is off.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        applyDockBadge(lastUpdateCount)
    }

    // Called when the last ForgedBrew window closes. If Keep in Dock is off, drop
    // the temporary Dock icon (back to menu-bar-only .accessory). If the menu
    // bar is on we stay alive; otherwise the app quits via the AppDelegate.
    func windowDidClose() {
        isWindowVisible = false
        if !keepInDock {
            // Return to menu-bar-only presentation; this also removes the
            // temporary Dock icon and its badge.
            NSApp.setActivationPolicy(.accessory)
        } else {
            // Permanent Dock icon — keep the badge stamped.
            applyDockBadge(lastUpdateCount)
        }
    }

    // MARK: - Dock visibility

    // Applies the Dock-visibility preference to the running app.
    static func applyDockVisibility(_ keepInDock: Bool) {
        let policy: NSApplication.ActivationPolicy = keepInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if keepInDock {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // The Dock tile only exists in .regular mode; re-stamp the badge so it
        // survives a policy switch back into the Dock.
        if keepInDock {
            shared.applyDockBadge(shared.lastUpdateCount)
        }
    }

    static func applySavedDockVisibilityAtLaunch() {
        let keep = UserDefaults.standard.object(forKey: keepInDockKey) as? Bool ?? true
        applyDockVisibility(keep)
    }

    // MARK: - Update badge (Dock + menu bar)

    // Records the latest available-update total and reflects it on every visible
    // surface: the Dock tile (when a Dock icon exists) and the menu bar extra
    // (when shown). Zero clears the badges. Call whenever the counts change.
    func updateBadge(count: Int) {
        lastUpdateCount = max(0, count)
        applyDockBadge(lastUpdateCount)
        applyStatusItemBadge(lastUpdateCount)
    }

    // Stamps the Dock tile badge (like Messages' unread count). An empty label
    // removes the badge. Harmless when there's no Dock icon (the tile is just
    // not shown), and it's re-stamped whenever a Dock icon (re)appears.
    private func applyDockBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - Menu bar extra

    func applySavedMenuBarVisibilityAtLaunch() {
        applyMenuBarVisibility(showInMenuBar)
    }

    private func applyMenuBarVisibility(_ show: Bool) {
        if show {
            installStatusItemIfNeeded()
            applyStatusItemBadge(lastUpdateCount)
        } else if let item = statusItem {
            // Tear the popover down with the item it hangs off: leaving it alive
            // would strand a SwiftUI tree observing the data services, and a
            // re-enabled menu bar would build a second one.
            popover?.performClose(nil)
            popover = nil
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // The icon is a single composed image: a beer-amber mug, plus (when
            // there are updates) a small red capsule badge in the top-right with
            // the count inside it — drawn here rather than as separate title text
            // so the number sits ON a colored capsule and reads clearly in both
            // light and dark menu bars.
            button.image = Self.makeStatusItemImage(count: lastUpdateCount, style: menuBarIconStyle)
            button.imagePosition = .imageOnly
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            // Left-click opens the popover; right-click (or ctrl-click) drops the
            // compact menu. Note we deliberately DON'T assign `item.menu` here:
            // a permanently attached menu makes AppKit swallow the left-click and
            // show the menu instead, which would leave the popover unreachable.
            // showStatusMenu() attaches it for the duration of one click instead.
            button.target = Self.statusTarget
            button.action = #selector(StatusItemTarget.statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    // MARK: - Popover

    // Left-click handler: show the popover, or dismiss it if it's already up.
    fileprivate func togglePopover() {
        guard let button = statusItem?.button else { return }
        let popover = self.popover ?? makePopover()
        self.popover = popover

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        // In menu-bar-only (.accessory) mode ForgedBrew isn't the active app, so
        // the popover's window won't take key focus on its own — the inline
        // admin-password field would look focused and silently swallow every
        // keystroke. Activate first, then make the popover's window key.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        // Transient: clicking away dismisses it, like every other menu bar
        // popover on the system. The cost is that a stray click can close it
        // mid-password-entry, which would strand the continuation
        // ensureSessionSudoPassword is parked on — StatusItemTarget's
        // popoverDidClose cancels any outstanding request to cover exactly that.
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = Self.statusTarget

        let root = MenuBarPopoverView(
            onOpenWindow: { [weak self] in
                self?.popover?.performClose(nil)
                Self.statusTarget.openApp()
            },
            onQuit: { [weak self] in
                self?.popover?.performClose(nil)
                self?.requestQuit()
            }
        )
        // AppDataService is read via @Environment on the windowed screens; inject
        // it here so the popover's view can use the same idiom. (AppUpdateService
        // is never in the environment — the popover reads that singleton direct.)
        .environment(AppDataService.shared)

        let controller = NSHostingController(rootView: root)
        // Let the popover size itself to the SwiftUI content: an empty
        // "up to date" state stays small, a long list grows to the view's own
        // max height and scrolls inside it.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        return popover
    }

    // Right-click handler: the compact power path — the three items the menu bar
    // had before the popover, for users who just want to open or quit without
    // waiting for the list to render.
    fileprivate func showStatusMenu() {
        guard let item = statusItem, let button = item.button else { return }
        popover?.performClose(nil)

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open ForgedBrew", action: #selector(StatusItemTarget.openApp), keyEquivalent: "")
        open.target = Self.statusTarget
        menu.addItem(open)
        // Refresh All: kicks off the same full app-wide refresh the app runs at
        // launch (Homebrew catalog + installed packages + Mac/other app updates),
        // straight from the menu bar without opening the window.
        let refresh = NSMenuItem(title: "Refresh All", action: #selector(StatusItemTarget.refreshAll), keyEquivalent: "r")
        refresh.target = Self.statusTarget
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ForgedBrew", action: #selector(StatusItemTarget.quitApp), keyEquivalent: "q")
        quit.target = Self.statusTarget
        menu.addItem(quit)

        // Attach the menu for THIS click only, then detach it — see the note in
        // installStatusItemIfNeeded about why a permanent item.menu would break
        // the left-click popover.
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    // Shows the update count next to the menu bar icon (e.g. "3"); clears it at
    // zero so the icon stands alone.
    private func applyStatusItemBadge(_ count: Int) {
        guard let button = statusItem?.button else { return }
        // Re-compose the icon image with (or without) the capsule badge. The
        // count is drawn INSIDE a red capsule overlaid on the mug, so there's no
        // separate title text to clear — but we keep the title empty defensively.
        button.image = Self.makeStatusItemImage(count: count, style: menuBarIconStyle)
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
    }

    // Builds the menu bar icon: a mug in the user's chosen colour, with a small
    // capsule badge in the top-right carrying the update count when count > 0.
    //
    // Two rendering modes, because they can't be reconciled:
    //
    //   • COLOURED (amber/blue/…): an ordinary non-template image. The mug keeps
    //     its fill and the badge is a red capsule with a white number. Looks
    //     identical in every menu bar, which is the point of choosing a colour.
    //
    //   • MONOCHROME: a TEMPLATE image, so macOS tints it for us — dark on a
    //     light menu bar, light on a dark one, dimmed on inactive displays.
    //     A template image is a MASK: every opaque pixel becomes the system's
    //     tint and colour information is discarded, so a red badge is simply not
    //     expressible. Instead the capsule is drawn solid and the number is
    //     KNOCKED OUT of it (see makeMonochromeImage) — the tint fills the pill
    //     and the count reads as menu-bar-coloured holes through it.
    // `style` is passed in rather than read off `shared`. That is NOT stylistic:
    // showInMenuBar's didSet fires during StartupSettings.init(), so this runs
    // while `shared`'s dispatch_once is still in flight. Touching `shared` from
    // here re-enters that once-token and traps —
    // "BUG IN CLIENT OF LIBDISPATCH: trying to lock recursively" — killing the
    // app at launch for anyone who has the menu bar enabled. Keep it a parameter.
    private static func makeStatusItemImage(count: Int, style: MenuBarIconStyle) -> NSImage? {
        guard let tint = style.tint else {
            return makeMonochromeImage(count: count)
        }
        let mugConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
        guard let mug = NSImage(systemSymbolName: "mug.fill", accessibilityDescription: "ForgedBrew")?
            .withSymbolConfiguration(mugConfig) else {
            return nil
        }
        mug.isTemplate = false

        // No badge: return the bare coloured mug.
        guard count > 0 else { return mug }

        // Canvas a little wider than the mug so the badge can sit at the corner
        // without being clipped. Height matches the mug; width adds room on the
        // right for the capsule.
        let mugSize = mug.size
        let extraRight: CGFloat = 9
        let canvasSize = NSSize(width: mugSize.width + extraRight, height: mugSize.height)

        let composed = NSImage(size: canvasSize)
        composed.lockFocus()

        // Draw the mug on the left.
        mug.draw(in: NSRect(x: 0, y: 0, width: mugSize.width, height: mugSize.height))

        // Badge text and capsule geometry.
        let text = "\(count)"
        let badgeFont = NSFont.systemFont(ofSize: 9, weight: .bold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: textAttrs)

        let hPad: CGFloat = 3.5
        let vPad: CGFloat = 1.5
        let capsuleHeight = textSize.height + vPad * 2
        // Keep it pill-shaped: at least as wide as it is tall.
        let capsuleWidth = max(textSize.width + hPad * 2, capsuleHeight)

        // Pin the capsule to the top-right of the canvas.
        let capsuleX = canvasSize.width - capsuleWidth
        let capsuleY = canvasSize.height - capsuleHeight
        let capsuleRect = NSRect(x: capsuleX, y: capsuleY, width: capsuleWidth, height: capsuleHeight)

        let capsulePath = NSBezierPath(roundedRect: capsuleRect,
                                       xRadius: capsuleHeight / 2,
                                       yRadius: capsuleHeight / 2)
        NSColor.systemRed.setFill()
        capsulePath.fill()

        // Center the count inside the capsule.
        let textOrigin = NSPoint(
            x: capsuleRect.midX - textSize.width / 2,
            y: capsuleRect.midY - textSize.height / 2
        )
        (text as NSString).draw(at: textOrigin, withAttributes: textAttrs)

        composed.unlockFocus()
        composed.isTemplate = false
        return composed
    }

    // The monochrome mug, drawn as a TEMPLATE image so macOS tints it to match
    // the menu bar (and dims it on inactive displays) — the one style that truly
    // blends in.
    //
    // The badge is the interesting part. Template images carry no colour, so the
    // usual red-capsule-with-white-text is impossible. Instead we fill the
    // capsule solid and then erase the number out of it with .destinationOut,
    // leaving transparent holes: when AppKit tints the mask, the pill becomes
    // menu-bar-coloured and the count shows through as negative space. Reads
    // clearly in both appearances without a single hardcoded colour.
    private static func makeMonochromeImage(count: Int) -> NSImage? {
        guard let mug = NSImage(systemSymbolName: "mug.fill", accessibilityDescription: "ForgedBrew") else {
            return nil
        }

        // No badge: the plain symbol as a template is already exactly right.
        guard count > 0 else {
            mug.isTemplate = true
            return mug
        }

        let mugSize = mug.size
        let extraRight: CGFloat = 9
        let canvasSize = NSSize(width: mugSize.width + extraRight, height: mugSize.height)

        let composed = NSImage(size: canvasSize)
        composed.lockFocus()

        // Draw the mug solid black — the tint replaces it anyway; only coverage
        // matters in a template image.
        NSColor.black.set()
        mug.draw(in: NSRect(x: 0, y: 0, width: mugSize.width, height: mugSize.height))

        let text = "\(count)"
        let badgeFont = NSFont.systemFont(ofSize: 9, weight: .bold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: NSColor.black
        ]
        let textSize = (text as NSString).size(withAttributes: textAttrs)

        let hPad: CGFloat = 3.5
        let vPad: CGFloat = 1.5
        let capsuleHeight = textSize.height + vPad * 2
        let capsuleWidth = max(textSize.width + hPad * 2, capsuleHeight)
        let capsuleRect = NSRect(x: canvasSize.width - capsuleWidth,
                                 y: canvasSize.height - capsuleHeight,
                                 width: capsuleWidth,
                                 height: capsuleHeight)

        // Solid pill.
        NSBezierPath(roundedRect: capsuleRect,
                     xRadius: capsuleHeight / 2,
                     yRadius: capsuleHeight / 2).fill()

        // Punch the count out of it. .destinationOut removes coverage where the
        // glyphs land, so the number becomes a hole rather than a mark.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        let textOrigin = NSPoint(
            x: capsuleRect.midX - textSize.width / 2,
            y: capsuleRect.midY - textSize.height / 2
        )
        (text as NSString).draw(at: textOrigin, withAttributes: textAttrs)
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        composed.unlockFocus()
        composed.isTemplate = true
        return composed
    }

    // Retained Objective-C target for the status-item menu actions.
    private static let statusTarget = StatusItemTarget()
}

// MARK: - Status item action target

/// The status item's button action and its NSMenuItem actions both need an
/// Objective-C target. This tiny retained object (held by
/// StartupSettings.statusTarget) routes the click (left → popover, right → menu),
/// backs the right-click menu's items — reopening the main window (showing a
/// temporary Dock icon if Keep in Dock is off), running a full refresh, or
/// quitting — and serves as the popover's delegate.
@MainActor
final class StatusItemTarget: NSObject {
    // The status item's single button action. AppKit sends this for both mouse
    // buttons (see sendAction(on:) in installStatusItemIfNeeded), so we inspect
    // the event that triggered it to decide which surface to show. Ctrl-click
    // counts as a right-click, matching the system convention.
    @objc func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            StartupSettings.shared.showStatusMenu()
        } else {
            StartupSettings.shared.togglePopover()
        }
    }

    @objc func openApp() {
        // showMainWindow() owns the whole job: pick the real main window (never
        // Settings/Welcome), re-show it or rebuild it if it was destroyed, and
        // only then flip the Dock icon on. The old code here raised whatever
        // canBecomeMain returned first and lit the Dock unconditionally, which
        // is why "Open ForgedBrew" could leave you with a Dock light and no app.
        StartupSettings.shared.showMainWindow()
    }

    @objc func quitApp() {
        StartupSettings.shared.requestQuit()
    }

    // Runs a full app-wide refresh from the menu bar. AppDataService.shared is
    // @MainActor and refreshEverything() is async; this @objc handler already
    // runs on the main thread, so we just hop into a Task to await it. The
    // service guards against re-entrancy (an in-flight refresh returns early),
    // so a double-click is harmless. No window is required — the menu bar badge
    // updates when the refresh lands.
    @objc func refreshAll() {
        Task { @MainActor in
            await AppDataService.shared.refreshEverything()
        }
    }

}

// MARK: - Popover delegate

extension StatusItemTarget: NSPopoverDelegate {
    // A transient popover closes on any click outside it. If it goes away while
    // the inline admin-password prompt is up, the continuation that
    // ensureSessionSudoPassword parked would never resume — the upgrade Task
    // would hang forever with no timeout — and pendingSudoRequest would linger,
    // so the next window to open would be ambushed by a password sheet for an
    // update the user had long since walked away from. Treat the dismissal as
    // what it is: a cancel.
    func popoverDidClose(_ notification: Notification) {
        let appData = AppDataService.shared
        if let request = appData.pendingSudoRequest {
            appData.provideSudoPassword(nil, for: request)
        }
    }
}