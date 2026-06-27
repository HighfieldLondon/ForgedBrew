import SwiftUI
import AppKit

// MARK: - TapsView
//
// The sidebar destination for Homebrew "taps" — the source repositories the
// user has added beyond the built-in homebrew/core + homebrew/cask catalogs.
// Mirrors the Installed screen's look: a searchable list where each tap expands
// to show the user's INSTALLED packages that came from it, with the same row
// features (open detail, update, uninstall, park) as the Installed view.
//
// Per tap the user can open its GitHub repo and Remove it (`brew untap`). brew
// refuses to untap while packages from it are still installed (we never force),
// so removing a tap NEVER deletes an installed app — it only drops the source
// repo, and the app keeps running but stops getting updates from that tap.

/// The Taps screen: a searchable, expandable list of the user's Homebrew taps,
/// with add/remove and per-tap drill-down into the installed packages it
/// provides.
struct TapsView: View {
    @Environment(AppDataService.self) private var appData
    // Page-local search, bound from the toolbar field (filters the tap list in
    // place by tap name, like the other inventory screens).
    var searchText: Binding<String> = .constant("")

    @State private var isRefreshing = false
    // Tap awaiting Remove confirmation.
    @State private var pendingRemove: Tap? = nil
    // Name of a tap currently being removed (shows a spinner on its row).
    @State private var removing: Set<String> = []
    // brew's error message from a failed untap, keyed by tap name (e.g. "still
    // installed" refusals), shown inline beneath the tap.
    @State private var removeErrors: [String: String] = [:]
    // Which taps are expanded to reveal their installed packages.
    @State private var expanded: Set<String> = []
    // Add-a-tap sheet state.
    @State private var showAddSheet = false

    private var query: String {
        searchText.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var filteredTaps: [Tap] {
        guard !query.isEmpty else { return appData.taps }
        return appData.taps.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if appData.taps.isEmpty {
                    emptyState
                } else if filteredTaps.isEmpty {
                    Text("No taps match “\(searchText.wrappedValue)”.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredTaps) { tap in
                            tapCard(tap)
                        }
                    }
                }
            }
            .padding(20)
        }
        .task {
            // Refresh the tap list when the screen appears so it reflects any
            // taps added/removed from the CLI since launch.
            await appData.loadTaps()
        }
        .confirmationDialog(
            pendingRemove.map { "Remove the “\($0.name)” tap?" } ?? "",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let tap = pendingRemove {
                Button("Remove Tap", role: .destructive) {
                    remove(tap)
                }
                Button("Cancel", role: .cancel) { pendingRemove = nil }
            }
        } message: {
            if let tap = pendingRemove {
                Text("This runs “brew untap \(tap.name)”, removing the tap's install recipes. Apps you already installed from it stay on your Mac and keep running — but Homebrew will no longer update or track them. Homebrew will refuse if packages are still installed from this tap. Re-add it any time with “brew tap \(tap.name)”.")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddTapSheet { name in
                await addTap(name)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                PageTitleLabel(title: "Taps")
                PageRefreshButton("Re-scan", isWorking: isRefreshing) {
                    Task {
                        isRefreshing = true
                        await appData.loadTaps()
                        isRefreshing = false
                    }
                }
                .help("Re-read the list of tapped repositories")
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add a Tap", systemImage: "plus")
                }
                .buttonStyle(PillActionButtonStyle(tint: .accentColor))
            }

            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("A tap is an extra source repository Homebrew installs from, beyond its built-in catalogs. Power users add taps (e.g. a vendor's own repo) to install software that isn't in the default catalog. Expand a tap to see which of your installed apps came from it. Removing a tap leaves those apps installed — it only stops Homebrew tracking and updating them from that source.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                Text("Expert Mode Caution! Removing a tap will disable all updates for the apps that came from it, and those apps will be removed from the Installed view in the sidebar. The apps stay installed and keep running — Homebrew just stops tracking and updating them.")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color.red)
            .padding(.top, 4)
        }
    }

    private var subtitle: String {
        let n = appData.taps.count
        return n == 1 ? "1 tap" : "\(n) taps"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No taps added")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Homebrew is using only its built-in catalogs. Add a tap to install software from another source repository.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Tap card

    // One tap rendered as a card: a header row (name, official/third-party
    // badge, installed-app count, last-commit, Repository/Remove actions) plus,
    // when expanded, the installed packages sourced from this tap. Official taps
    // (core/cask) intentionally omit the Remove button.
    @ViewBuilder
    private func tapCard(_ tap: Tap) -> some View {
        let isExpanded = expanded.contains(tap.name)
        let installed = appData.installedPackages(forTap: tap)
        let isRemoving = removing.contains(tap.name)

        VStack(alignment: .leading, spacing: 0) {
            // Header row: name + badges + actions.
            HStack(spacing: 10) {
                Button {
                    toggle(tap)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)

                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(tap.name)
                            .font(.system(size: 14, weight: .semibold))
                        if tap.official {
                            Label("Official", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.blue)
                                .labelStyle(.titleAndIcon)
                        } else {
                            Label("Third-party", systemImage: "link")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.purple)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    HStack(spacing: 10) {
                        Text(installedCountText(installed.count))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let last = tap.lastCommit {
                            Label("Updated \(last)", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if let remote = tap.remote, let url = URL(string: remote) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Repository", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(PillActionButtonStyle(tint: Color.secondary))
                    .help(Text(verbatim: "Open this tap's repository: \(remote)"))
                }

                if isRemoving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Removing…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if !tap.official {
                    // Official taps (core/cask) shouldn't be removed from here.
                    Button {
                        removeErrors[tap.name] = nil
                        pendingRemove = tap
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(PillActionButtonStyle(tint: ActionColors.destructive))
                    .help("Remove this tap (runs “brew untap”). Installed apps stay; they just stop updating from this tap.")
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture { toggle(tap) }

            // Inline error from a failed untap (e.g. packages still installed).
            if let err = removeErrors[tap.name] {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            // Expanded: the installed packages that came from this tap, using
            // the same row component (and actions) as the Installed view.
            if isExpanded {
                Divider().padding(.horizontal, 12)
                if installed.isEmpty {
                    Text("No packages from this tap are currently installed.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(installed) { pkg in
                            InstalledRowView(
                                package: pkg,
                                dependencies: pkg.dependencies,
                                isBusy: appData.isOperationInFlight(token: pkg.token),
                                onTap: { _ in },
                                onUninstall: { _ in },
                                onUpdate: { _ in },
                                isParked: appData.isParked(pkg),
                                onPark: { p, type, duration in
                                    Task { await appData.park(package: p, parkType: type, duration: duration) }
                                },
                                onUnpark: { p in
                                    Task { await appData.unpark(token: p.token, type: p.type) }
                                },
                                progress: appData.installProgress[pkg.token]
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func installedCountText(_ n: Int) -> String {
        switch n {
        case 0: return "No installed apps from this tap"
        case 1: return "1 installed app"
        default: return "\(n) installed apps"
        }
    }

    // MARK: Actions

    private func toggle(_ tap: Tap) {
        if expanded.contains(tap.name) {
            expanded.remove(tap.name)
        } else {
            expanded.insert(tap.name)
        }
    }

    // Run `brew untap` for the tap, showing a per-row spinner meanwhile. On
    // failure (most often brew refusing because packages are still installed),
    // stash the message in removeErrors so it renders inline beneath the tap.
    private func remove(_ tap: Tap) {
        pendingRemove = nil
        removing.insert(tap.name)
        Task {
            let result = await appData.removeTap(tap.name)
            removing.remove(tap.name)
            if !result.success {
                removeErrors[tap.name] = result.message.isEmpty
                    ? "Could not remove this tap."
                    : result.message
            }
        }
    }

    private func addTap(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        _ = await appData.cli.addTap(trimmed)
        await appData.loadTaps()
    }
}

// MARK: - Add Tap sheet

/// Modal sheet to add a tap. Collects a "user/repo" identifier and hands it to
/// the host's async add closure; disables Add while empty or in flight.
private struct AddTapSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String) async -> Void

    @State private var name = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Tap")
                .font(.title2.bold())
            Text("Enter a tap in the form user/repo (e.g. hashicorp/tap). Homebrew clones it from GitHub. You can then install packages that live in that tap.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("user/repo", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .disableAutocorrection(true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    working = true
                    Task {
                        await onAdd(name)
                        working = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
    }
}
