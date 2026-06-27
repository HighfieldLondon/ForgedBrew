import Foundation

// MARK: - AppLocationSettings
//
// A single, app-wide source of truth for WHICH folders ForgedBrew scans when it
// looks for installed .app bundles. macOS apps can live in two places:
//   • /Applications            — system-wide (visible to all users)
//   • ~/Applications           — the current user's personal Applications folder
// Different Macs use one, the other, or both, so every scan (Adopt, Quarantine,
// size probes, duplicate detection, …) should consult this helper rather than
// hardcoding "/Applications".
//
// Both standard locations default to ON. The user can toggle either in Settings;
// the preference persists in UserDefaults under the keys below. Because the keys
// default to true when unset (object(forKey:) == nil), a fresh install scans
// both folders out of the box.
//
// In addition, the user can add their own CUSTOM folders (for apps installed
// somewhere unusual). Those are persisted in the on-disk config file
// (~/.config/forgedbrew/config.json) via ForgedBrewConfig — NOT UserDefaults — so they
// survive upgrades, reinstalls, and reboots and can be inspected by hand. They
// are always scanned (there is no per-folder toggle; remove a folder to stop
// scanning it).
//
// This type is intentionally a plain enum of static helpers (no instances): it
// reads UserDefaults / the config file on demand so any caller — actors, views,
// services — gets the current setting without wiring up observation. SwiftUI
// views that want a live toggle bind to the same keys via @AppStorage (see the
// key constants).

/// App-wide source of truth for which folders ForgedBrew scans for installed
/// .app bundles: the two standard Applications folders (each toggleable via
/// UserDefaults, defaulting ON) plus any user-added custom folders (persisted in
/// the on-disk config). A stateless enum of static helpers read on demand, so
/// any caller — actor, view, or service — sees the current setting with no
/// observation wiring.
nonisolated enum AppLocationSettings {
    // UserDefaults keys. Kept here so the @AppStorage toggles in Settings and
    // the readers in services never drift apart.
    static let scanSystemApplicationsKey = "forgedbrewScanSystemApplications"
    static let scanUserApplicationsKey = "forgedbrewScanUserApplications"

    // How many custom folders a user may add. Kept small on purpose: the two
    // standard Applications folders cover almost everyone, and a short list
    // keeps the Settings UI tidy.
    static let maxCustomLocations = 5

    // The absolute system-wide Applications path.
    static var systemApplicationsPath: String { "/Applications" }

    // The current user's personal Applications path (e.g. ~/Applications).
    static var userApplicationsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Applications")
    }

    // Whether each location is enabled. Unset (nil) reads as true so both
    // folders are scanned by default.
    static var scansSystemApplications: Bool {
        UserDefaults.standard.object(forKey: scanSystemApplicationsKey) as? Bool ?? true
    }
    static var scansUserApplications: Bool {
        UserDefaults.standard.object(forKey: scanUserApplicationsKey) as? Bool ?? true
    }

    // The user's custom scan folders, read from the on-disk config. Empty when
    // none have been added.
    static var customLocations: [String] {
        ForgedBrewConfig.load().customAppLocations
    }

    // The directories to scan, honoring the user's toggles plus any custom
    // folders. If the user disables BOTH standard folders AND has no custom
    // folders, we fall back to /Applications so scans never silently return
    // nothing (a disabled-everything state is almost certainly a mistake, and an
    // empty scan looks identical to "nothing found"). Custom folders are always
    // included when present, and the whole list is de-duplicated by resolved
    // path so the same folder added twice (or symlinked) is only scanned once.
    static var searchDirectories: [String] {
        var dirs: [String] = []
        if scansSystemApplications { dirs.append(systemApplicationsPath) }
        if scansUserApplications { dirs.append(userApplicationsPath) }
        dirs.append(contentsOf: customLocations)

        // De-duplicate by resolved path while keeping order.
        var seen = Set<String>()
        let deduped = dirs.filter { path in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return seen.insert(resolved).inserted
        }

        return deduped.isEmpty ? [systemApplicationsPath] : deduped
    }

    // Convenience: every top-level .app bundle across the enabled folders,
    // de-duplicated by resolved (symlink-followed) path so an app present in
    // both folders — or symlinked between them — appears once. Returns the
    // resolved absolute path plus the bundle's display name ("Foo.app").
    // Shared by Adopt, Quarantine, and any other bundle scan.
    static func installedAppBundles() -> [(path: String, name: String)] {
        let fm = FileManager.default
        var results: [(path: String, name: String)] = []
        var seen = Set<String>()
        for dir in searchDirectories {
            guard fm.fileExists(atPath: dir) else { continue }
            let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                let full = (dir as NSString).appendingPathComponent(entry)
                let resolved = URL(fileURLWithPath: full).resolvingSymlinksInPath().path
                guard seen.insert(resolved).inserted else { continue }
                results.append((path: resolved, name: entry))
            }
        }
        return results
    }
}
