import Foundation
import SwiftUI
@preconcurrency import Sparkle

// A thin, observable wrapper around Sparkle's standard updater controller.
//
// `SPUStandardUpdaterController` is the recommended entry point for SwiftUI /
// AppKit apps using Sparkle 2.x. We create it once (started automatically) and
// expose just what the UI needs: whether a check can currently run, and a way
// to trigger a user-initiated check from a menu command.
//
// Feed URL + public EdDSA key live in Info.plist (SUFeedURL / SUPublicEDKey);
// automatic checks are controlled by SUEnableAutomaticChecks.

// Dedicated Sparkle updater delegate.
//
// SPUUpdater's `delegate` is set once, at controller-init time (it is not an
// assignable property afterward), so the delegate must be a separate object we
// can hand to the initializer. Its only job is the pre-relaunch hook: it flips
// StartupSettings.isInstallingUpdate so applicationShouldTerminate allows
// Sparkle's quit through instead of cancelling it via the menu-bar keep-alive
// rule (which is what was stalling the install).
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        DispatchQueue.main.async {
            StartupSettings.shared.isInstallingUpdate = true
        }
    }
}

@MainActor
@Observable
final class Updater {
    // The standard controller owns the SPUUpdater instance and the standard
    // user-driver (the built-in update UI). startingUpdater: true begins the
    // scheduled-check cycle immediately on launch.
    private let controller: SPUStandardUpdaterController

    // Held strongly because SPUUpdater keeps only a weak reference to its delegate.
    private let updaterDelegate = UpdaterDelegate()

    // Mirrors updater.canCheckForUpdates so a menu item can enable/disable
    // itself. Kept in sync via KVO on the underlying SPUUpdater.
    var canCheckForUpdates: Bool = false

    private var observation: NSKeyValueObservation?

    init() {
        // Pass our delegate in at init time so we receive Sparkle's pre-relaunch
        // callback. startingUpdater: true begins the scheduled-check cycle now.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )

        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            // KVO callbacks may arrive off the main actor. Read the new value
            // here, then hop to the main actor to update our @Observable state.
            let newValue = updater.canCheckForUpdates
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = newValue
            }
        }
    }

    // User-initiated "Check for Updates…" — shows Sparkle's standard UI.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    // MARK: - Automatic update preferences (Settings UI)
    //
    // These proxy to the live SPUUpdater. Sparkle persists them in the standard
    // user defaults keys (SUEnableAutomaticChecks / SUAutomaticallyUpdate), so a
    // runtime change here overrides the Info.plist default and survives relaunch.
    // Exposing them lets a Homebrew-installed user turn the in-app updater off and
    // let "brew upgrade" manage the app instead.

    // Whether Sparkle checks for updates on its own schedule.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    // Whether Sparkle silently downloads found updates (installed on next launch).
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    // Timestamp of the last update check Sparkle performed, for the Settings card.
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}

// A reusable menu command (placed in the app's About/Info group) that triggers
// a manual update check and disables itself when a check can't run.
struct CheckForUpdatesView: View {
    let updater: Updater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
