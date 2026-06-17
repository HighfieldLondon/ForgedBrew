import SwiftUI
import ServiceManagement
import AppKit

// MARK: - Startup, Dock & Menu Bar behavior
//
// Backs the toggles in Settings ▸ General ▸ Startup. The model is deliberately
// just three independent switches — no separate "start hidden" option:
//
//   • Load on startup  — registers the app as a macOS login item (SMAppService).
//   • Show in menu bar — adds an NSStatusItem (menu bar extra) with a menu to
//     open the window or quit, and shows the available-update count beside it.
//     When ON, a login launch starts FORGEDBREW HIDDEN in the menu bar (no
//     window, no Dock bounce) — i.e. "show in menu bar" implies start-hidden.
//   • Keep in Dock     — when ON, the Dock icon is shown permanently. When OFF,
//     there's no Dock icon while the app sits in the menu bar; opening the
//     window from the menu bar shows a TEMPORARY Dock icon for as long as the
//     window is open, then it disappears again when the window closes.
//
// Also owns the DOCK BADGE: the number of available updates (Homebrew +
// Mac/other apps, parked excluded) shown on the Dock icon — like Messages'
// unread count. The badge shows whenever a Dock icon exists (permanent, or the
// temporary one while a window is open). Call updateBadge(count:) on changes.
@MainActor
@Observable
final class StartupSettings {
    static let shared = StartupSettings()

    // Persisted preferences.
    static let keepInDockKey = "forgedbrewKeepInDock"
    static let showInMenuBarKey = "forgedbrewShowInMenuBar"
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

    // True while a menu bar extra is actually installed. Used as a belt-and-
    // suspenders guard so the app never quits out from under a live menu bar
    // icon, even if the showInMenuBar bool and the real status item ever drift.
    var hasStatusItem: Bool { statusItem != nil }

    private init() {
        // Seed from the real system state on creation.
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        keepInDock = UserDefaults.standard.object(forKey: Self.keepInDockKey) as? Bool ?? true
        showInMenuBar = UserDefaults.standard.object(forKey: Self.showInMenuBarKey) as? Bool ?? false
        backgroundRefreshEnabled = UserDefaults.standard.object(forKey: Self.backgroundRefreshEnabledKey) as? Bool ?? true
        let savedHours = UserDefaults.standard.object(forKey: Self.backgroundRefreshHoursKey) as? Int
        backgroundRefreshHours = Self.backgroundRefreshChoices.contains(savedHours ?? 0)
            ? (savedHours ?? Self.defaultBackgroundRefreshHours)
            : Self.defaultBackgroundRefreshHours
        notifyOnNewUpdates = UserDefaults.standard.object(forKey: Self.notifyOnNewUpdatesKey) as? Bool ?? true
    }

    // Re-reads the live login-item status (call when the Settings pane appears).
    func refreshFromSystem() {
        let enabled = (SMAppService.mainApp.status == .enabled)
        if enabled != launchAtLogin {
            _suppressApply = true
            launchAtLogin = enabled
            _suppressApply = false
        }
    }

    private var _suppressApply = false

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
            button.image = Self.makeStatusItemImage(count: lastUpdateCount)
            button.imagePosition = .imageOnly
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        }

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open ForgedBrew", action: #selector(StatusItemTarget.openApp), keyEquivalent: "")
        open.target = Self.statusTarget
        menu.addItem(open)
        // Refresh All: kicks off the same full app-wide refresh the app runs at
        // launch (Homebrew catalog + installed packages + Mac/other app updates),
        // straight from the menu bar without opening the window. Disabled while a
        // refresh is already in flight so the user cannot stack overlapping runs.
        let refresh = NSMenuItem(title: "Refresh All", action: #selector(StatusItemTarget.refreshAll), keyEquivalent: "r")
        refresh.target = Self.statusTarget
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ForgedBrew", action: #selector(StatusItemTarget.quitApp), keyEquivalent: "q")
        quit.target = Self.statusTarget
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    // Shows the update count next to the menu bar icon (e.g. "3"); clears it at
    // zero so the icon stands alone.
    private func applyStatusItemBadge(_ count: Int) {
        guard let button = statusItem?.button else { return }
        // Re-compose the icon image with (or without) the capsule badge. The
        // count is drawn INSIDE a red capsule overlaid on the mug, so there's no
        // separate title text to clear — but we keep the title empty defensively.
        button.image = Self.makeStatusItemImage(count: count)
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
    }

    // Builds the menu bar icon: a beer-amber mug, with a small red capsule badge
    // in the top-right carrying the update count when count > 0. Returning a
    // single non-template NSImage keeps the amber fill (and the badge) visible in
    // both light and dark menu bars. The image is sized to the menu bar height.
    private static func makeStatusItemImage(count: Int) -> NSImage? {
        let beer = NSColor(calibratedRed: 0.83, green: 0.55, blue: 0.10, alpha: 1.0)
        let mugConfig = NSImage.SymbolConfiguration(paletteColors: [beer])
        guard let mug = NSImage(systemSymbolName: "mug.fill", accessibilityDescription: "ForgedBrew")?
            .withSymbolConfiguration(mugConfig) else {
            return nil
        }
        mug.isTemplate = false

        // No badge: return the bare amber mug.
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

    // Retained Objective-C target for the status-item menu actions.
    private static let statusTarget = StatusItemTarget()
}

// MARK: - Status item action target
//
// NSMenuItem actions need an ObjC target. This tiny retained object reopens the
// main window (showing a temporary Dock icon if Keep in Dock is off) or quits.
@MainActor
final class StatusItemTarget: NSObject {
    @objc func openApp() {
        // Show the window and let StartupSettings handle the Dock icon/badge.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // No window object exists (rare) — ask AppKit to reopen.
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
        StartupSettings.shared.windowDidBecomeVisible()
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