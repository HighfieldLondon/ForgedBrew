import Foundation
import AppIntents

// Exposes ForgedBrew actions to Shortcuts, Spotlight, and Siri via the AppIntents
// framework. Both intents drive the shared AppDataService, reusing the same
// install pipeline + state the UI uses (so installs are logged, installed state
// refreshes, and Spotlight re-indexes automatically).

// MARK: - List Installed

struct ListInstalledIntent: AppIntent {
    static var title: LocalizedStringResource = "List Installed Packages"
    static var description = IntentDescription(
        "Lists the Homebrew casks and formulae currently installed, as tracked by ForgedBrew."
    )

    // Returns the installed package tokens plus a human-readable summary dialog.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let appData = AppDataService.shared

        // Make sure we have a current snapshot.
        if appData.installedPackages.isEmpty {
            await appData.refreshInstalled()
        }

        let tokens = appData.installedPackages.map { $0.token }.sorted()
        let dialog: IntentDialog
        if tokens.isEmpty {
            dialog = IntentDialog("No packages are currently installed.")
        } else {
            dialog = IntentDialog("\(tokens.count) packages installed.")
        }
        return .result(value: tokens, dialog: dialog)
    }
}

// MARK: - Install Cask

struct InstallCaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Install Cask"
    static var description = IntentDescription(
        "Installs a Homebrew cask by its token (for example, \"rectangle\")."
    )

    // The cask token to install (e.g. "visual-studio-code").
    @Parameter(title: "Cask Token")
    var token: String

    // Surface the parameter in the Shortcuts summary line.
    static var parameterSummary: some ParameterSummary {
        Summary("Install cask \(\.$token)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: IntentDialog("Please provide a cask token to install."))
        }

        let appData = AppDataService.shared

        // Drive the same streaming install pipeline the UI uses; drain it to
        // completion so the intent doesn't return before the install finishes.
        let stream = appData.install(cask: trimmed)
        var lastLine = ""
        for await line in stream {
            lastLine = line
        }

        let failed = lastLine.lowercased().contains("error")
            || lastLine.lowercased().contains("failed")
        if failed {
            return .result(dialog: IntentDialog("Install of \(trimmed) did not complete: \(lastLine)"))
        }
        return .result(dialog: IntentDialog("Installed \(trimmed)."))
    }
}

// MARK: - Open Cask

// Brings ForgedBrew to the foreground and opens the in-app detail page for a given
// cask token. Used as the follow-through for Shortcuts/Siri and as the tap
// target for catalog deep-links. Honors the product's in-app-navigation rule:
// it opens the detail card inside ForgedBrew rather than launching the browser.
struct OpenCaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Cask"
    static var description = IntentDescription(
        "Opens the ForgedBrew detail page for a cask by its token (for example, \"rectangle\")."
    )

    // Bring the app to the front when this intent runs so the detail page is
    // visible immediately.
    static var openAppWhenRun: Bool = true

    // The cask token to open (e.g. "visual-studio-code").
    @Parameter(title: "Cask Token")
    var token: String

    static var parameterSummary: some ParameterSummary {
        Summary("Open cask \(\.$token)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: IntentDialog("Please provide a cask token to open."))
        }

        // Publish the deep-link request; DetailRouter resolves it to the in-app
        // detail page (retrying once the catalog has loaded on a cold launch).
        AppDataService.shared.requestDeepLink(token: trimmed)
        return .result(dialog: IntentDialog("Opening \(trimmed) in ForgedBrew."))
    }
}

// MARK: - Shortcuts Provider

struct ForgedBrewShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListInstalledIntent(),
            phrases: [
                "List installed packages in \(.applicationName)",
                "Show my \(.applicationName) packages"
            ],
            shortTitle: "List Installed",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: InstallCaskIntent(),
            phrases: [
                "Install a cask with \(.applicationName)",
                "Install a package in \(.applicationName)"
            ],
            shortTitle: "Install Cask",
            systemImageName: "arrow.down.app"
        )
        AppShortcut(
            intent: OpenCaskIntent(),
            phrases: [
                "Open a cask in \(.applicationName)",
                "Show a cask in \(.applicationName)"
            ],
            shortTitle: "Open Cask",
            systemImageName: "square.and.arrow.up.on.square"
        )
    }
}
