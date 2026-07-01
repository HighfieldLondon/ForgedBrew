import SwiftUI

// MARK: - ParkedView
//
// The sidebar destination for "parked" packages. Parking holds an installed
// package out of the Updates list and out of "Update All" so brew never tries
// to upgrade (and possibly downgrade/clobber) it — while ForgedBrew keeps tracking
// it so we can still surface "a newer version is available" and let the user
// Unpark when ready.
//
// This is ForgedBrew's "Park" feature. The view leads with a
// "why you'd do this" explainer (requested), then lists each parked package with
// its park type, an "update available" hint, controls to change how long it
// stays parked, and an Unpark button.

struct ParkedView: View {
    @Environment(AppDataService.self) var appData
    // Parked Mac App Store / Other (non-Homebrew) app updates live in their own
    // service; we surface them here alongside parked Homebrew packages.
    //
    // DORMANT (2026-07): non-Homebrew app parking is no longer creatable — the
    // Park control was removed when the Mac Store/Other Apps screens became
    // awareness-only (see the dormant note in AppUpdateService "Park / Unpark").
    // This "non-Homebrew apps parked" subsection is retained so any historical
    // app-parks stay visible/unparkable, and to revisit alongside a better
    // topgrade integration. Homebrew package parking (the rest of this screen)
    // is unaffected.
    @State private var appUpdateService = AppUpdateService.shared

    var body: some View {
        @Bindable var appData = appData
        let items = appData.parkedPackages()
        let parkedApps = appUpdateService.parkedList()

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                whyPark

                if items.isEmpty && parkedApps.isEmpty {
                    emptyState
                } else {
                    // Section 1 — Parked Homebrew packages.
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Parked Homebrew",
                                      systemImage: "shippingbox",
                                      count: items.count)
                        if items.isEmpty {
                            Text("No Homebrew packages are parked.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(items, id: \.record.id) { item in
                                    ParkedRowView(record: item.record, package: item.package)
                                }
                            }
                        }
                    }

                    // Section 2 — Parked Mac App Store / Other apps.
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Parked Mac/Other apps",
                                      systemImage: "app.badge",
                                      count: parkedApps.count)
                        if parkedApps.isEmpty {
                            Text("No Mac App Store or other (non-Homebrew) apps are parked.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(parkedApps) { record in
                                    ParkedAppUpdateRow(record: record, service: appUpdateService)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .task {
            // Make sure parked state reflects the latest DB + auto-unpark sweep
            // (expired durations / newer versions) when the view appears.
            await appData.loadParked()
        }
    }

    // A section title with an icon and a count pill.
    private func sectionHeader(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            Spacer()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            PageTitleLabel(title: "Parked")
            Text(parkedCountLabel)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var parkedCountLabel: String {
        let brew = appData.parkedRecords.count
        let apps = appUpdateService.parkedList().count
        let n = brew + apps
        return n == 1 ? "1 parked item" : "\(n) parked items"
    }

    // The requested "why you'd do this" explainer, shown in the sidebar Parked
    // area. Two concrete reasons that map to the handoff doc's motivating cases.
    private var whyPark: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Why park an update?", systemImage: "questionmark.circle")
                .font(.system(size: 13, weight: .semibold))

            Text("Parking holds a package out of the Updates list and out of Update All, so Homebrew won't try to upgrade it. ForgedBrew keeps tracking it, so you'll still see when a newer version is available and can Unpark whenever you're ready.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                whyRow(
                    icon: "arrow.down.circle",
                    title: "Your installed build is ahead of Homebrew's",
                    detail: "Some apps update themselves to a build newer than the brew cask. \"Upgrading\" would actually roll it back — park it to avoid the downgrade."
                )
                whyRow(
                    icon: "hand.raised",
                    title: "You want to stay on the current version",
                    detail: "Hold a known-good version while you wait out a buggy release, finish a project, or test compatibility on your own schedule."
                )
                whyRow(
                    icon: "app.badge",
                    title: "Control Mac & other app updates separately",
                    detail: "Mac App Store and other non-Homebrew apps update through the app itself (or the App Store), not Homebrew. Park them here to stop ForgedBrew nudging you, and update each on your own terms \u{2014} independently of how you manage your Homebrew packages."
                )
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private func whyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "parkingsign.circle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Nothing parked")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Park an app from the Updates or Installed list to hold its version and skip it in Update All.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - ParkedRowView

/// One parked Homebrew package: identity, installed/latest versions, current
/// park status, an Unpark button, an "update available" hint, and a menu to
/// re-park with a different park type/duration without leaving the screen.
struct ParkedRowView: View {
    @Environment(AppDataService.self) var appData
    let record: ParkedApp
    // The currently-installed package, if it's still installed. nil means the
    // user uninstalled it while parked (the next refresh prunes stale parks).
    let package: InstalledPackage?

    // True when Homebrew now offers a version newer than what we recorded at
    // park time — the "update available" hint.
    private var updateAvailable: Bool {
        guard let latest = package?.outdatedInfo?.currentVersion else { return false }
        guard let parked = record.parkedVersion else { return package?.isOutdated ?? false }
        return latest != parked
    }

    // Prefer the live installed version; fall back to the version brew recorded
    // in its outdated report (covers casks whose installedVersion isn't tracked
    // directly).
    private var installedVersion: String? {
        package?.installedVersion ?? package?.outdatedInfo?.installedVersion
    }

    private var latestVersion: String? {
        package?.outdatedInfo?.currentVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: record.parkType.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(InstalledRowView.displayName(for: record.token))
                            .font(.system(size: 14, weight: .semibold))
                        if record.type == .formula {
                            Text("formula")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                    }
                    Text(record.token)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    versionLine

                    parkStatusLine
                }

                Spacer()

                Button {
                    Task { await appData.unpark(token: record.token, type: record.type) }
                } label: {
                    Label("Unpark", systemImage: "play.circle")
                }
                .buttonStyle(OutlinedButtonStyle())
                .controlSize(.small)
                .help("Unpark this package: return it to the Updates list and Update All so it can be upgraded again.")
            }

            if updateAvailable {
                Label("A newer version is available — Unpark to update.", systemImage: "arrow.up.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }

            Divider()

            parkTypeControls
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var versionLine: some View {
        if package == nil {
            Text("No longer installed")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if let installed = installedVersion {
            HStack(spacing: 4) {
                Text("Installed \(installed)")
                if let latest = latestVersion, latest != installed {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                    Text("latest \(latest)")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var parkStatusLine: some View {
        Text(statusText)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    // Human-readable park status, branching on how the package was parked:
    // forever, until a newer version ships (noting the held version), or until a
    // set expiry date.
    private var statusText: String {
        switch record.parkType {
        case .indefinite:
            return "Parked indefinitely · since \(Self.dateLabel(record.parkedAt))"
        case .untilNextVersion:
            let base = record.parkedVersion.map { " (held at \($0))" } ?? ""
            return "Parked until next version\(base)"
        case .duration:
            if let expires = record.expiresAt {
                return "Parked until \(Self.dateLabel(expires))"
            }
            return "Parked for a set time"
        }
    }

    // Lets the user change how long the package stays parked without leaving the
    // Parked view. Re-parking with the same package overwrites the existing
    // record (DatabaseManager.park upserts on the (token,type) primary key).
    @ViewBuilder
    private var parkTypeControls: some View {
        if let package {
            HStack(spacing: 10) {
                Text("Keep parked:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Menu {
                    Button {
                        Task { await appData.park(package: package, parkType: .indefinite) }
                    } label: {
                        Label(ParkType.indefinite.displayName, systemImage: ParkType.indefinite.symbol)
                    }
                    Button {
                        Task { await appData.park(package: package, parkType: .untilNextVersion) }
                    } label: {
                        Label(ParkType.untilNextVersion.displayName, systemImage: ParkType.untilNextVersion.symbol)
                    }
                    Menu {
                        ForEach(ParkDuration.allCases, id: \.self) { d in
                            Button(d.rawValue) {
                                Task {
                                    await appData.park(
                                        package: package,
                                        parkType: .duration,
                                        duration: d
                                    )
                                }
                            }
                        }
                    } label: {
                        Label(ParkType.duration.displayName, systemImage: ParkType.duration.symbol)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: record.parkType.symbol)
                        Text(record.parkType.displayName)
                    }
                    .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()
            }
        }
    }

    static func dateLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }
}
