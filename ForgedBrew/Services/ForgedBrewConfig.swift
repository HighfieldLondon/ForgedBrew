import Foundation

// Reads optional local configuration for ForgedBrew from a JSON file the user
// drops into their home directory. Keeps secrets (like the SerpApi image-search
// key) out of the app bundle and out of source control. Absent file or missing
// keys simply yield nil, and features degrade gracefully (e.g. screenshots fall
// back to the GitHub README / social-preview image, then the "About this app"
// text panel).
//
// Expected file: ~/.config/forgedbrew/config.json
// Example contents:
//   {
//     "serpApiKey": "YOUR_SERPAPI_KEY",
//     "customAppLocations": ["/Users/yourname/Tools", "/opt/MyApps"]
//   }
//
// SerpApi (https://serpapi.com) offers a free tier (250 searches/month, no card
// to start) and a dedicated Google Images endpoint. Because we cache screenshot
// results per cask token +
// version on disk, each app is only searched once per version — so the free
// monthly quota stretches a long way.
//
// Custom app locations (added for the "App Locations" Settings tab) are extra
// folders the user picks when they install apps somewhere other than the two
// standard Applications folders. They are persisted HERE — in the on-disk
// config file rather than UserDefaults — specifically so they survive app
// upgrades, reinstalls, and reboots, and so a user can inspect/edit them by
// hand. AppLocationSettings reads them on demand and folds them into every
// bundle scan.
nonisolated struct ForgedBrewConfig: Sendable {
    let serpApiKey: String?
    // Extra folders to scan for installed .app bundles, beyond the two standard
    // Applications locations. Stored as absolute paths. Empty when unset.
    let customAppLocations: [String]

    // Loads config from ~/.config/forgedbrew/config.json. Always succeeds: a
    // missing or malformed file yields a config with no key set.
    static func load() -> ForgedBrewConfig {
        // One-time migration: if a config from an earlier version exists and we
        // have not yet created our own, copy it over so the user keeps their
        // SerpApi key and custom app locations across the upgrade.
        migrateLegacyConfigIfNeeded()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("forgedbrew", isDirectory: true)
            .appendingPathComponent("config.json")

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ForgedBrewConfig(serpApiKey: nil, customAppLocations: [])
        }

        // Prefer the current key name; accept a couple of friendly aliases so a
        // hand-edited config is forgiving.
        let raw = (json["serpApiKey"] as? String)
            ?? (json["serpapiKey"] as? String)
            ?? (json["serpApiApiKey"] as? String)
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Custom locations: accept an array of strings, drop blanks, normalize,
        // and de-duplicate (order-preserving). The file is hand-editable and the
        // legacy-config migration copies an old file verbatim, so duplicates are
        // possible — and the Settings list keys its SwiftUI ForEach by the path
        // string, where duplicate ids would break row identity/removal. Dedupe
        // here so every consumer (the list AND AppLocationSettings scanning) sees
        // a unique set.
        var seenLocations = Set<String>()
        let rawLocations = (json["customAppLocations"] as? [String])
            ?? (json["customScanLocations"] as? [String])
            ?? []
        let locations = rawLocations
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenLocations.insert($0).inserted }

        return ForgedBrewConfig(
            serpApiKey: (key?.isEmpty == false) ? key : nil,
            customAppLocations: locations
        )
    }

    // Copies a legacy config from an earlier version to the new
    // ~/.config/forgedbrew/config.json on first launch, but only when the new
    // file does not already exist. Best-effort and silent: any failure simply
    // leaves the user starting fresh.
    private static func migrateLegacyConfigIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let configRoot = home.appendingPathComponent(".config", isDirectory: true)

        let newDir = configRoot.appendingPathComponent("forgedbrew", isDirectory: true)
        let newURL = newDir.appendingPathComponent("config.json")
        // If we already have a config, never overwrite it.
        guard !fm.fileExists(atPath: newURL.path) else { return }

        let oldURL = configRoot
            .appendingPathComponent("caskade", isDirectory: true)
            .appendingPathComponent("config.json")
        guard fm.fileExists(atPath: oldURL.path) else { return }

        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try? fm.copyItem(at: oldURL, to: newURL)
    }

    // Path to the config file, creating the ~/.config/forgedbrew directory if it
    // doesn't exist yet. Returns nil only if the directory can't be created.
    private static func fileURL(creatingDir: Bool) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("forgedbrew", isDirectory: true)
        if creatingDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("config.json")
    }

    // Reads the current JSON object from disk (or an empty object), preserving
    // any keys we don't manage. Shared by the save helpers so writing one
    // setting never clobbers another.
    private static func loadRawJSON(from url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return existing
    }

    @discardableResult
    private static func writeRawJSON(_ json: [String: Any], to url: URL) -> Bool {
        guard let out = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try out.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // Persists the SerpApi key to ~/.config/forgedbrew/config.json, preserving any
    // other keys already in the file. Passing nil or an empty string removes the
    // key (writing an empty object if nothing else is present). Returns true on
    // success. Used by the in-app Settings screen so users can paste their own
    // key without hand-editing the file.
    @discardableResult
    static func saveSerpApiKey(_ key: String?) -> Bool {
        guard let url = fileURL(creatingDir: true) else { return false }

        // Start from whatever is already in the file (preserve unknown keys).
        var json = loadRawJSON(from: url)

        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            json["serpApiKey"] = trimmed
        } else {
            json.removeValue(forKey: "serpApiKey")
        }

        return writeRawJSON(json, to: url)
    }

    // Persists the user's custom app-scan locations, preserving any other keys
    // already in the file (e.g. the SerpApi key). Blank entries are dropped and
    // the list is de-duplicated while keeping the user's order. Passing an empty
    // array removes the key entirely. Returns true on success.
    @discardableResult
    static func saveCustomAppLocations(_ locations: [String]) -> Bool {
        guard let url = fileURL(creatingDir: true) else { return false }

        var json = loadRawJSON(from: url)

        var seen = Set<String>()
        let cleaned = locations
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }

        if cleaned.isEmpty {
            json.removeValue(forKey: "customAppLocations")
        } else {
            json["customAppLocations"] = cleaned
        }

        return writeRawJSON(json, to: url)
    }
}
