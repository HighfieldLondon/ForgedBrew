import Foundation
import AppKit
@preconcurrency import UserNotifications
import Network

// MARK: - Background update checks
//
// Keeps ForgedBrew's available-update counts fresh while the app is running —
// crucially INCLUDING menu-bar-only / headless mode, where no window is on
// screen. This is the CleanMyMac-style "quietly check in the background"
// behavior: a lightweight repeating timer (NOT BGTaskScheduler, which is
// iOS/Catalyst-only) that, on each tick:
//
//   1. Runs a full inventory refresh via AppDataService.refreshEverything()
//      (Homebrew installed/outdated + Mac/other-app scan). Catalog fetches
//      already honor a 6-hour TTL, so the network footprint stays small.
//   2. Re-stamps the Dock + menu-bar badge with the new total.
//   3. If the count went UP since the last check and the user opted in, posts a
//      native macOS notification ("N updates available") so they find out even
//      when only the menu bar is showing.
//
// Interval and on/off come from StartupSettings (user-configurable in
// Settings ▸ Updates). The coordinator restarts its timer live when those
// change (StartupSettings.backgroundRefreshDidChange).
//
// Battery/Network friendly: skips a tick when offline (NWPathMonitor), and the
// underlying refreshEverything() already coalesces overlapping runs, so a manual
// rescan and a background tick can never double-run.
@MainActor
final class BackgroundRefreshCoordinator {
    static let shared = BackgroundRefreshCoordinator()

    private let settings = StartupSettings.shared

    // The AppDataService whose refreshEverything()/outdated counts we drive.
    // Set once at launch via configure(appData:); the timer is a no-op until then.
    private weak var appData: AppDataService?

    // The running timer loop, if active. Cancelled on stop()/restart.
    private var loopTask: Task<Void, Never>?

    // Network reachability. We skip a tick when there's no path so a check never
    // fails noisily offline; the next tick (or app foreground) tries again.
    private let pathMonitor = NWPathMonitor()
    private var isOnline = true

    // The available-update total observed at the END of the last completed check,
    // used to detect a RISE (new updates) for the notification. -1 means "no
    // baseline yet" so the very first background check never fires a notification
    // (it just establishes the baseline).
    private var lastKnownTotal = -1

    // True once we've asked the system for notification authorization, so we only
    // prompt once per launch.
    private var didRequestNotificationAuth = false

    private init() {
        pathMonitor.pathUpdateHandler = { path in
            let online = (path.status == .satisfied)
            Task { @MainActor in BackgroundRefreshCoordinator.shared.isOnline = online }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ai.perplexity.forgedbrew.netpath"))
    }

    // Wires up the data service and starts the timer (if enabled). Call once from
    // applicationDidFinishLaunching. Also installs the live-restart hook so
    // toggling the setting or changing the interval reschedules immediately.
    func configure(appData: AppDataService) {
        self.appData = appData
        settings.backgroundRefreshDidChange = { [weak self] in
            self?.restart()
        }
        start()
    }

    // (Re)starts the repeating loop if the feature is enabled; otherwise stops.
    func start() {
        loopTask?.cancel()
        guard settings.backgroundRefreshEnabled else {
            loopTask = nil
            return
        }
        let hours = max(1, settings.backgroundRefreshHours)
        let intervalNanos = UInt64(hours) * 3_600 * 1_000_000_000
        loopTask = Task { [weak self] in
            // Don't immediately re-scan at launch — the app already does a full
            // refreshEverything() on first window/launch. Wait one interval, then
            // check on each subsequent interval until cancelled.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                if Task.isCancelled { return }
                await self?.runCheck()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // Records the current available-update total as the notification baseline so
    // the next background check only notifies on a genuine RISE. Call right after
    // the app launch refresh stamps the badge, so pre-existing updates the user
    // can already see in the window do not trigger a notification.
    func setBaseline(total: Int) {
        lastKnownTotal = total
    }

    private func restart() {
        start()
    }

    // One background check: refresh everything, restamp the badge, and notify on
    // a rise. Safe to call any time; no-ops gracefully if offline or unconfigured.
    private func runCheck() async {
        guard let appData else { return }
        guard isOnline else { return }

        await appData.refreshEverything()

        let total = appData.outdatedExcludingParked().count
            + AppUpdateService.shared.visibleUpdates().count

        // Keep the Dock + menu-bar badge current even when no window is open.
        settings.updateBadge(count: total)

        // Notify only when the count actually ROSE since the last check (new
        // updates appeared) and the user opted in. The first check just sets the
        // baseline so we never fire a notification for pre-existing updates.
        if settings.notifyOnNewUpdates,
           lastKnownTotal >= 0,
           total > lastKnownTotal {
            postNewUpdatesNotification(total: total, newlyAvailable: total - lastKnownTotal)
        }
        lastKnownTotal = total
    }

    // MARK: - Notification

    private func postNewUpdatesNotification(total: Int, newlyAvailable: Int) {
        didRequestNotificationAuth = true
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus

            var authorized = (status == .authorized || status == .provisional)
            if status == .notDetermined {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized else { return }  // denied → respect it; badge still updates.

            let content = UNMutableNotificationContent()
            content.title = newlyAvailable == 1 ? "A new update is available"
                                                : "New updates are available"
            let plural = total == 1 ? "update" : "updates"
            content.body = "ForgedBrew found \(total) \(plural) ready to install."
            content.sound = .default
            // nil trigger → deliver immediately.
            let request = UNNotificationRequest(
                identifier: "ai.perplexity.forgedbrew.new-updates",
                content: content,
                trigger: nil)
            try? await center.add(request)
        }
    }
}
