import SwiftUI

// Shows Homebrew's OWN version and a one-tap "Update Homebrew" that runs
// `brew update` (the command that fetches the newest Homebrew itself plus all
// formula/cask definitions). We do NOT predict whether an update is needed --
// Homebrew updates via git commits, not just tagged releases, so a version
// comparison is unreliable. Like the established Homebrew GUIs, Update is a
// refresh action and we report whatever `brew update` actually did. Mirrors
// FullDiskAccessBanner styling; sits just below it in MaintenanceView.
struct HomebrewStatusBanner: View {
    @Bindable var metrics: MaintenanceMetrics
    let cli: BrewCLIService

    // Convenience reads of the shared MaintenanceMetrics state. The banner is a
    // pure projection of these three flags into title/subtitle/icon/button.
    private var installed: String? { metrics.brewInstalledVersion }
    private var loading: Bool { metrics.brewVersionLoading }
    private var updating: Bool { metrics.brewUpdating }
    // "Not installed" only once the version probe has finished (not loading) and
    // still found nothing -- so we don't flash a scary "missing" state mid-check.
    private var notInstalled: Bool { !loading && installed == nil }

    private var iconName: String {
        notInstalled ? "questionmark.circle.fill" : "shippingbox.fill"
    }

    private var iconColor: Color {
        notInstalled ? .secondary : .blue
    }

    // Title carries the detected version when known; a bare "Homebrew" stands in
    // while still checking or when brew is absent.
    private var title: String {
        guard let installed else { return "Homebrew" }
        return "Homebrew \(installed)"
    }

    private var subtitle: String {
        // Once an update has run, show its result; otherwise a neutral hint.
        if let message = metrics.brewUpdateMessage, !message.isEmpty {
            return message
        }
        if loading && installed == nil { return "Checking Homebrew version…" }
        if notInstalled { return "Homebrew was not found on this Mac." }
        return "Fetch the latest Homebrew and package definitions."
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Update is always available as a refresh action while Homebrew is
            // present. Disabled only while a run is in flight or brew is missing.
            Button {
                Task { await metrics.updateHomebrew(cli: cli) }
            } label: {
                if updating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Updating…")
                    }
                } else {
                    Text("Update Homebrew")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(updating || notInstalled)
        }
        .padding(14)
        .background(AnyShapeStyle(Color.blue.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}
