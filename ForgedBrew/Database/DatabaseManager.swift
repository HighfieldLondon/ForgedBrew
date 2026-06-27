import Foundation
import GRDB

// MARK: - DatabaseManager (GRDB / SQLite persistence)
//
// The app's single on-disk store, living at
// ~/Library/Application Support/ForgedBrew/forgedbrew.db (a GRDB DatabaseQueue,
// so all access is serialized through one connection). It plays two distinct
// roles:
//
//   1. Catalog CACHE — a local mirror of the Homebrew catalog so the app opens
//      instantly offline and only hits the network to refresh. The `casks`,
//      `formulas`, and `installedPackages` tables are disposable: they are
//      wiped/replaced wholesale on every catalog/install refresh and can be
//      rebuilt from the Homebrew API at any time.
//
//   2. User DATA — the things the user authored and must never lose across a
//      refresh: `favorites`, `userNotes`, `tags` + `itemTags`, `parkedApps`,
//      and the GitHub-license cache (`githubMeta`). These are deliberately kept
//      in their OWN tables (not as columns on the catalog rows) precisely so the
//      catalog-replace step above can't clobber them.
//
// Schema evolution is handled by GRDB's DatabaseMigrator (migrations v1…v10
// registered in init). GRDB records which migrations have run and NEVER re-runs
// a completed one, so every schema change must be a new, append-only migration —
// see the per-migration comments for why several are standalone rather than
// folded into v1.
//
// Declared as an `actor`: the type is the app's serialization point for all DB
// I/O, and the async read/write API below hops onto the GRDB queue off the main
// actor so SwiftUI never blocks on disk.

// MARK: - Cask catalog row
//
// One row of the `casks` catalog-cache table, with conversions to/from the
// domain CaskMetadata. Catalog rows are replaced wholesale on every refresh
// (saveCasks uses INSERT … onConflict .replace), so this record holds only the
// browse/detail fields — user-authored state (favorite flag aside) lives in
// separate tables that survive the replace.
struct CaskRecord: FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "casks"

    var token: String
    var name: String
    var desc: String?
    var homepage: String?
    var downloadURL: String?
    var version: String?
    var category: String
    var autoUpdates: Bool
    var deprecated: Bool
    var githubUrl: String?
    var installCount30d: Int
    var installCount90d: Int
    var installCount365d: Int
    var isFavorite: Bool
    var userNotes: String?
    var cachedAt: Double?
    var tapGitHead: String?

    init(row: Row) {
        self.token = row["token"]
        self.name = row["name"]
        self.desc = row["desc"]
        self.homepage = row["homepage"]
        self.downloadURL = row["downloadURL"]
        self.version = row["version"]
        self.category = row["category"]
        self.autoUpdates = row["autoUpdates"]
        self.deprecated = row["deprecated"]
        self.githubUrl = row["githubUrl"]
        self.installCount30d = row["installCount30d"]
        self.installCount90d = row["installCount90d"]
        self.installCount365d = row["installCount365d"]
        self.isFavorite = row["isFavorite"]
        self.userNotes = row["userNotes"]
        self.cachedAt = row["cachedAt"]
        self.tapGitHead = row["tapGitHead"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["token"] = token
        container["name"] = name
        container["desc"] = desc
        container["homepage"] = homepage
        container["downloadURL"] = downloadURL
        container["version"] = version
        container["category"] = category
        container["autoUpdates"] = autoUpdates
        container["deprecated"] = deprecated
        container["githubUrl"] = githubUrl
        container["installCount30d"] = installCount30d
        container["installCount90d"] = installCount90d
        container["installCount365d"] = installCount365d
        container["isFavorite"] = isFavorite
        container["userNotes"] = userNotes
        container["cachedAt"] = cachedAt
        container["tapGitHead"] = tapGitHead
    }

    // Builds a row from live catalog metadata. Install counts are passed in
    // (they come from a separate analytics feed) and the favorite flag / notes
    // are reset to defaults here because their source of truth is the dedicated
    // favorites/userNotes tables, not this row.
    init(cask: CaskMetadata, installCount30d: Int = 0, installCount90d: Int = 0, installCount365d: Int = 0) {
        self.token = cask.token
        // CaskMetadata.name is an array of aliases; persist it as a JSON string
        // in the single TEXT `name` column (decoded back in toCaskMetadata).
        let encoder = JSONEncoder()
        self.name = (try? String(data: encoder.encode(cask.name), encoding: .utf8)) ?? "[]"
        self.desc = cask.desc
        self.homepage = cask.homepage
        self.downloadURL = cask.downloadURL
        self.version = cask.version
        self.category = cask.category.rawValue
        self.autoUpdates = cask.autoUpdates ?? false
        self.deprecated = cask.deprecated
        self.githubUrl = cask.githubURL?.absoluteString
        self.installCount30d = installCount30d
        self.installCount90d = installCount90d
        self.installCount365d = installCount365d
        self.isFavorite = false
        self.userNotes = nil
        self.cachedAt = Date().timeIntervalSince1970
        self.tapGitHead = cask.tapGitHead
    }

    // Reconstructs a CaskMetadata. Because CaskMetadata has no memberwise public
    // initializer covering every field, we round-trip the row through a JSON dict
    // and CaskMetadata's Decodable conformance (mirroring the Homebrew API JSON
    // shape), falling back to a minimal hand-built value if that decode fails.
    func toCaskMetadata() -> CaskMetadata {
        let nameArray: [String]
        if let data = name.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            nameArray = decoded
        } else {
            nameArray = [token]
        }

        let dict: [String: Any] = [
            "token": token,
            "name": nameArray,
            "desc": desc as Any,
            "homepage": homepage as Any,
            "url": downloadURL as Any,
            "version": version as Any,
            "auto_updates": autoUpdates,
            "deprecated": deprecated,
            "tap_git_head": tapGitHead as Any,
            "depends_on": NSNull(),
            "ruby_source_path": NSNull(),
            "install_count_30d": installCount30d,
            "install_count_90d": installCount90d,
            "install_count_365d": installCount365d
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            return try JSONDecoder().decode(CaskMetadata.self, from: data)
        } catch {
            // The JSON round-trip above failed (e.g. a stale on-disk row predates
            // a CaskMetadata field change). Degrade gracefully rather than
            // crashing the process on a persisted-data read: build a minimal cask
            // directly via the memberwise initializer so the catalog still loads
            // and the offending row simply shows sparse detail.
            NSLog("ForgedBrew: CaskRecord fell back to minimal CaskMetadata for '%@': %@",
                  token, String(describing: error))
            return CaskMetadata(
                token: token,
                name: nameArray.isEmpty ? [token] : nameArray,
                desc: desc,
                homepage: homepage,
                downloadURL: downloadURL,
                version: version,
                deprecated: deprecated
            )
        }
    }
}

// MARK: - Formula catalog row
//
// One row of the `formulas` catalog-cache table. A deliberately lightweight
// mirror: it stores only the fields browse + detail need (no head version,
// dependencies, or build deps — see toFormulaMetadata). Keyed by `name`, and
// like casks it is replaced wholesale on every catalog refresh.
struct FormulaRecord: FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "formulas"

    var name: String
    var fullName: String?
    var desc: String?
    var homepage: String?
    var license: String?
    var stableVersion: String?
    var deprecated: Bool
    var disabled: Bool
    var installCount30d: Int
    var cachedAt: Double?

    init(row: Row) {
        self.name = row["name"]
        self.fullName = row["fullName"]
        self.desc = row["desc"]
        self.homepage = row["homepage"]
        self.license = row["license"]
        self.stableVersion = row["stableVersion"]
        self.deprecated = row["deprecated"]
        self.disabled = row["disabled"]
        self.installCount30d = row["installCount30d"]
        self.cachedAt = row["cachedAt"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["name"] = name
        container["fullName"] = fullName
        container["desc"] = desc
        container["homepage"] = homepage
        container["license"] = license
        container["stableVersion"] = stableVersion
        container["deprecated"] = deprecated
        container["disabled"] = disabled
        container["installCount30d"] = installCount30d
        container["cachedAt"] = cachedAt
    }

    init(formula: FormulaMetadata, installCount30d: Int = 0) {
        self.name = formula.name
        self.fullName = formula.fullName
        self.desc = formula.desc
        self.homepage = formula.homepage
        self.license = formula.license
        self.stableVersion = formula.versions.stable
        self.deprecated = formula.deprecated
        self.disabled = formula.disabled
        self.installCount30d = installCount30d
        self.cachedAt = Date().timeIntervalSince1970
    }

    func toFormulaMetadata() -> FormulaMetadata {
        // The formulas table is a lightweight catalog cache: it does not store
        // head version, dependencies, or build dependencies, so those come back
        // empty/nil. That's fine for browse + detail; richer per-formula detail
        // can be lazily fetched from the API when needed.
        FormulaMetadata(
            name: name,
            fullName: fullName ?? name,
            desc: desc,
            homepage: homepage,
            license: license,
            versions: FormulaVersions(stable: stableVersion, head: nil),
            dependencies: [],
            buildDependencies: [],
            deprecated: deprecated,
            disabled: disabled,
            installCount30d: installCount30d
        )
    }
}

// MARK: - Installed-package row
//
// One row of the `installedPackages` cache — the locally-known state of a
// package the user has installed (version, outdated flag, target version, and
// whether it was installed on request vs pulled in as a dependency). Keyed by
// (token, type). Rebuilt wholesale from a `brew` scan on every refresh; cached
// here so the Installed list and "Installed by me" filter render at cold launch
// before that scan completes.
struct InstalledRecord: FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "installedPackages"
    var token: String
    var type: String
    var installedVersion: String?
    var isOutdated: Bool
    var currentVersion: String?
    var installedOnRequest: Bool

    init(row: Row) {
        self.token = row["token"]
        self.type = row["type"]
        self.installedVersion = row["installedVersion"]
        self.isOutdated = row["isOutdated"]
        self.currentVersion = row["currentVersion"]
        // Default to top-level when the column is missing/NULL (rows written
        // before the v9 migration, or partial writes).
        self.installedOnRequest = (row["installedOnRequest"] as Bool?) ?? true
    }

    func encode(to container: inout PersistenceContainer) {
        container["token"] = token
        container["type"] = type
        container["installedVersion"] = installedVersion
        container["isOutdated"] = isOutdated
        container["currentVersion"] = currentVersion
        container["installedOnRequest"] = installedOnRequest
    }

    func toInstalledPackage() -> InstalledPackage {
        let pkgType = PackageType(rawValue: type) ?? .cask
        var outdatedInfo: OutdatedInfo? = nil
        if isOutdated, let curr = currentVersion {
            outdatedInfo = OutdatedInfo(
                currentVersion: curr,
                installedVersion: installedVersion ?? "",
                pinned: false
            )
        }
        return InstalledPackage(
            token: token,
            type: pkgType,
            installedVersion: installedVersion,
            isOutdated: isOutdated,
            outdatedInfo: outdatedInfo,
            installedOnRequest: installedOnRequest
        )
    }

    init(package: InstalledPackage) {
        self.token = package.token
        self.type = package.type.rawValue
        self.installedVersion = package.installedVersion
        self.isOutdated = package.isOutdated
        self.currentVersion = package.outdatedInfo?.currentVersion
        self.installedOnRequest = package.installedOnRequest
    }
}

/// The app's single SQLite store, accessed as a shared actor. Owns one GRDB
/// `DatabaseQueue` (serialized access) and exposes an async read/write API for
/// the catalog cache and all user data (favorites, notes, tags, parks). All
/// schema setup runs once in `init` via the registered migrations.
actor DatabaseManager {
    static let shared = DatabaseManager()
    private let dbQueue: DatabaseQueue

    // Opens (creating if needed) the on-disk database and runs all pending
    // migrations before the actor is usable. Anything fatal here (no
    // Application Support dir, open failure, migration failure) aborts launch:
    // the app cannot function without its store, and continuing would risk
    // operating on a half-initialized/corrupt DB.
    private init() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            fatalError("ForgedBrew: Application Support directory not found — cannot open database")
        }
        // Migrate any legacy Application Support folder to "ForgedBrew" on first
        // launch so existing data (DB + cache) is preserved across upgrades.
        let legacyDir = appSupport.appendingPathComponent("Hopsight")
        let forgedDir = appSupport.appendingPathComponent("ForgedBrew")
        if fm.fileExists(atPath: legacyDir.path), !fm.fileExists(atPath: forgedDir.path) {
            try? fm.moveItem(at: legacyDir, to: forgedDir)
        }
        try? fm.createDirectory(at: forgedDir, withIntermediateDirectories: true)
        // Second leg of the rename: the database file itself was once
        // "hopsight.db". Move it (and its WAL/SHM sidecars, which must travel
        // with it or SQLite sees a torn database) to the new "forgedbrew.db"
        // name, but only if the new file doesn't already exist.
        let legacyDB = forgedDir.appendingPathComponent("hopsight.db")
        let dbURL = forgedDir.appendingPathComponent("forgedbrew.db")
        if fm.fileExists(atPath: legacyDB.path), !fm.fileExists(atPath: dbURL.path) {
            try? fm.moveItem(at: legacyDB, to: dbURL)
            for suffix in ["-wal", "-shm"] {
                let from = URL(fileURLWithPath: legacyDB.path + suffix)
                let to = URL(fileURLWithPath: dbURL.path + suffix)
                if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                    try? fm.moveItem(at: from, to: to)
                }
            }
        }

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: dbURL.path)
        } catch {
            fatalError("Failed to open database: \(error.localizedDescription)")
        }

        var migrator = DatabaseMigrator()

        // v1 establishes the original schema: the cask catalog cache plus the
        // first user-data and bookkeeping tables.
        //   • casks            — cask catalog cache (replaced on refresh).
        //   • installedPackages — locally-known installed state, keyed (token,type).
        //   • favorites        — user-starred tokens, source of truth for "starred".
        //   • userNotes        — per-token free-text notes the user authored.
        //   • installHistory   — append-only log of install/uninstall/upgrade events.
        //   • analyticsCache   — blob cache for computed analytics, keyed by key.
        //   • appMetadata      — generic key/value store (refresh timestamps, ETags).
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE casks (
                    token TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    desc TEXT,
                    homepage TEXT,
                    version TEXT,
                    category TEXT,
                    autoUpdates INTEGER DEFAULT 0,
                    deprecated INTEGER DEFAULT 0,
                    githubUrl TEXT,
                    installCount30d INTEGER DEFAULT 0,
                    installCount90d INTEGER DEFAULT 0,
                    isFavorite INTEGER DEFAULT 0,
                    userNotes TEXT,
                    cachedAt REAL,
                    tapGitHead TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE installedPackages (
                    token TEXT NOT NULL,
                    type TEXT NOT NULL,
                    installedVersion TEXT,
                    isOutdated INTEGER DEFAULT 0,
                    currentVersion TEXT,
                    PRIMARY KEY (token, type)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE favorites (
                    token TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    addedAt REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE userNotes (
                    token TEXT PRIMARY KEY,
                    note TEXT,
                    updatedAt REAL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE installHistory (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    token TEXT NOT NULL,
                    type TEXT NOT NULL,
                    action TEXT NOT NULL,
                    version TEXT,
                    timestamp REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE analyticsCache (
                    key TEXT PRIMARY KEY,
                    data BLOB NOT NULL,
                    cachedAt REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE appMetadata (
                    key TEXT PRIMARY KEY,
                    value TEXT
                )
                """)
        }

        // v2 adds full-text search over the cask catalog. `casks_fts` is an
        // external-content FTS5 index (content=casks): it stores no copy of the
        // text, just the inverted index, and is seeded from the existing rows.
        // The three triggers (ai/ad/au) keep the index in lock-step with INSERT/
        // DELETE/UPDATE on `casks` — the 'delete' sentinel rows are the FTS5
        // idiom for removing stale terms before re-indexing on update. searchCasks
        // queries this index.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE casks_fts USING fts5(
                    token, name, desc, homepage, category,
                    content=casks, content_rowid=rowid
                )
                """)
            try db.execute(sql: """
                INSERT INTO casks_fts(rowid, token, name, desc, homepage, category)
                SELECT rowid, token, name, desc, homepage, category FROM casks
                """)
            try db.execute(sql: """
                CREATE TRIGGER casks_ai AFTER INSERT ON casks BEGIN
                    INSERT INTO casks_fts(rowid, token, name, desc, homepage, category)
                    VALUES (new.rowid, new.token, new.name, new.desc, new.homepage, new.category);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER casks_ad AFTER DELETE ON casks BEGIN
                    INSERT INTO casks_fts(casks_fts, rowid, token, name, desc, homepage, category)
                    VALUES ('delete', old.rowid, old.token, old.name, old.desc, old.homepage, old.category);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER casks_au AFTER UPDATE ON casks BEGIN
                    INSERT INTO casks_fts(casks_fts, rowid, token, name, desc, homepage, category)
                    VALUES ('delete', old.rowid, old.token, old.name, old.desc, old.homepage, old.category);
                    INSERT INTO casks_fts(rowid, token, name, desc, homepage, category)
                    VALUES (new.rowid, new.token, new.name, new.desc, new.homepage, new.category);
                END
                """)
        }

        // v3 creates the formulas catalog-cache table. This MUST be its own
        // migration (not folded into v1): databases created before the Formulae
        // feature already ran v1, and GRDB never re-runs a completed migration —
        // so without a fresh migration the formulas table would never exist on
        // existing installs and every saveFormulas() would throw "no such table".
        migrator.registerMigration("v3") { db in
            // IF NOT EXISTS makes this idempotent: some early builds folded the
            // formulas table into v1, so a database created by one of those will
            // already have it. Without IF NOT EXISTS this CREATE would throw
            // "table formulas already exists" and crash on launch.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS formulas (
                    name TEXT PRIMARY KEY,
                    fullName TEXT,
                    desc TEXT,
                    homepage TEXT,
                    license TEXT,
                    stableVersion TEXT,
                    deprecated INTEGER DEFAULT 0,
                    disabled INTEGER DEFAULT 0,
                    installCount30d INTEGER DEFAULT 0,
                    cachedAt REAL
                )
                """)
        }

        // v4 adds a standalone cache for GitHub-derived per-cask metadata
        // (currently the SPDX license). It is intentionally a SEPARATE table
        // keyed by token rather than a column on `casks`: saveCasks() replaces
        // whole cask rows on every catalog refresh (insert onConflict .replace),
        // which would wipe a license column. A separate table survives refreshes
        // and is only ever written when a detail page resolves a real license
        // from GitHub. `fetchedAt` lets us age entries out if we ever want to.
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS githubMeta (
                    token TEXT PRIMARY KEY,
                    license TEXT,
                    fetchedAt REAL
                )
                """)
        }

        // v5 adds the parkedApps table backing the "Park" feature: a parked
        // (token, type) is excluded from the Updates list and "Update All" but
        // still tracked, so the Parked view can surface a newer Homebrew version
        // and let the user Unpark + update. Its own table (not a column on
        // installedPackages, which is wiped + rebuilt on every refreshInstalled)
        // so parks survive refreshes and relaunches. parkType / parkedVersion /
        // expiresAt back our Park design outline. parkedAt is a sort key.
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS parkedApps (
                    token TEXT NOT NULL,
                    type TEXT NOT NULL,
                    parkType TEXT NOT NULL,
                    parkedAt REAL NOT NULL,
                    parkedVersion TEXT,
                    expiresAt REAL,
                    PRIMARY KEY (token, type)
                )
                """)
        }

        // v6 backs the user-defined tagging feature in our design outline.
        // Two tables: `tags` holds the tag definitions (name/color/icon), and
        // `itemTags` is a join table mapping a tag to the (token, type) packages
        // that carry it. A single tag can span both casks and formulae, which is
        // why membership is keyed by (tagId, token, type) rather than living on
        // either catalog table. ON DELETE CASCADE drops a tag's memberships when
        // the tag itself is deleted. Memberships intentionally survive catalog
        // refreshes (casks/formulas rows are replaced wholesale on refresh), so
        // there is deliberately no FK from itemTags back to casks/formulas.
        migrator.registerMigration("v6") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tags (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    color TEXT NOT NULL,
                    icon TEXT NOT NULL,
                    createdAt REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS itemTags (
                    tagId INTEGER NOT NULL,
                    token TEXT NOT NULL,
                    type TEXT NOT NULL,
                    addedAt REAL NOT NULL,
                    PRIMARY KEY (tagId, token, type),
                    FOREIGN KEY (tagId) REFERENCES tags(id) ON DELETE CASCADE
                )
                """)
            // Speeds up the per-package "which tags does this carry?" lookup
            // on every detail page open.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_itemTags_token
                ON itemTags (token, type)
                """)
        }

        migrator.registerMigration("v7") { db in
            try db.execute(sql: "ALTER TABLE casks ADD COLUMN installCount365d INTEGER DEFAULT 0")
        }

        // De-duplicate tags by name and forbid future duplicates.
        //
        // The original `tags` schema had no UNIQUE constraint on `name`, and
        // although createTag() does a case-insensitive existence check before
        // inserting, a race (or older builds) could leave two tags with the same
        // name — e.g. a stray second "Utilities". This migration collapses every
        // name-collision group onto its lowest id: itemTags memberships from the
        // losing duplicates are re-pointed at the survivor (INSERT OR IGNORE so a
        // package already carrying the survivor isn't double-added), the loser
        // tags are deleted, and a UNIQUE index on name COLLATE NOCASE is added so
        // the database itself now prevents the situation from ever recurring.
        migrator.registerMigration("v8") { db in
            // Re-point memberships from every non-minimal duplicate onto the
            // minimum id sharing the same (case-insensitive) name.
            try db.execute(sql: """
                UPDATE OR IGNORE itemTags
                SET tagId = (
                    SELECT MIN(t2.id) FROM tags t2
                    JOIN tags t1 ON t1.id = itemTags.tagId
                    WHERE t2.name = t1.name COLLATE NOCASE
                )
                WHERE tagId NOT IN (
                    SELECT MIN(id) FROM tags GROUP BY name COLLATE NOCASE
                )
                """)
            // Drop any membership rows still pointing at a soon-to-be-deleted
            // duplicate (i.e. the OR IGNORE skipped them because the survivor
            // already carried that package).
            try db.execute(sql: """
                DELETE FROM itemTags
                WHERE tagId NOT IN (
                    SELECT MIN(id) FROM tags GROUP BY name COLLATE NOCASE
                )
                """)
            // Delete the duplicate tag rows, keeping the lowest id per name.
            try db.execute(sql: """
                DELETE FROM tags
                WHERE id NOT IN (
                    SELECT MIN(id) FROM tags GROUP BY name COLLATE NOCASE
                )
                """)
            // Enforce uniqueness going forward.
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_name_unique
                ON tags (name COLLATE NOCASE)
                """)
        }

        // v9 adds the installedOnRequest flag to installedPackages so the
        // "Installed by me" vs "Dependency" filter survives a cold launch
        // (the cached install list is read from here before the first brew
        // scan finishes). Default 1 (top-level) is the safe assumption for any
        // rows written before this column existed; the next scan corrects them.
        migrator.registerMigration("v9") { db in
            try db.execute(sql: """
                ALTER TABLE installedPackages
                ADD COLUMN installedOnRequest INTEGER DEFAULT 1
                """)
        }

        // v10: persist the cask download/artifact URL. It is frequently a GitHub
        // releases URL even when the homepage is a vendor site, letting us
        // recover the source repo (CaskMetadata.githubURL) for the About tab,
        // license, and stars. Nullable; backfilled on the next catalog refresh.
        migrator.registerMigration("v10") { db in
            try db.execute(sql: "ALTER TABLE casks ADD COLUMN downloadURL TEXT")
        }

        do {
            try migrator.migrate(queue)
        } catch {
            fatalError("Failed to migrate database: \(error.localizedDescription)")
        }

        self.dbQueue = queue
    }

    // MARK: - Cask catalog (read/write)

    // Upserts the full cask catalog. Each row is replaced on token conflict, so
    // a refresh overwrites stale catalog fields in place; user data in the
    // separate favorites/notes/tags tables is untouched.
    func saveCasks(_ casks: [CaskMetadata]) async throws {
        try await dbQueue.write { db in
            for cask in casks {
                let record = CaskRecord(cask: cask)
                try record.insert(db, onConflict: .replace)
            }
        }
    }

    // Persist a resolved GitHub SPDX license for a cask token. Called from the
    // detail page once a real license is fetched from GitHub. Survives catalog
    // refreshes (separate table) and app relaunches.
    func saveCaskGitHubLicense(token: String, license: String?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO githubMeta (token, license, fetchedAt) VALUES (?, ?, ?)",
                arguments: [token, license, Date().timeIntervalSince1970]
            )
        }
    }

    // Bulk-load every persisted GitHub license, keyed by token, so the catalog
    // load can stamp known licenses onto CaskMetadata in one read. Tokens with a
    // NULL stored license (a confirmed "no detectable license") are omitted.
    func fetchAllCaskGitHubLicenses() async throws -> [String: String] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT token, license FROM githubMeta WHERE license IS NOT NULL"
            )
            var map: [String: String] = [:]
            for row in rows {
                let token: String = row["token"]
                if let license: String = row["license"] {
                    map[token] = license
                }
            }
            return map
        }
    }

    func fetchAllCasks() async throws -> [CaskMetadata] {
        try await dbQueue.read { db in
            // Exclude deprecated casks so they never surface in the catalog,
            // Home feed, browse grids, or anywhere that reads the full list.
            // The rows stay in the DB (favorites / installed lookups by token
            // still resolve); they're just filtered out of discovery surfaces.
            let records = try CaskRecord
                .filter(sql: "deprecated = 0")
                .fetchAll(db)
            return records.map { $0.toCaskMetadata() }
        }
    }

    // MARK: - Formula catalog (read/write)

    // Upserts the full formula catalog, mirroring saveCasks (replace on `name`).
    func saveFormulas(_ formulas: [FormulaMetadata]) async throws {
        try await dbQueue.write { db in
            for formula in formulas {
                let record = FormulaRecord(formula: formula, installCount30d: formula.installCount30d)
                try record.insert(db, onConflict: .replace)
            }
        }
    }

    func fetchAllFormulas() async throws -> [FormulaMetadata] {
        try await dbQueue.read { db in
            // Mirror fetchAllCasks: exclude deprecated AND disabled formulae so
            // they never surface in discovery surfaces. Rows stay in the DB so
            // installed/favorite lookups by name still resolve.
            let records = try FormulaRecord
                .filter(sql: "deprecated = 0 AND disabled = 0")
                .fetchAll(db)
            return records.map { $0.toFormulaMetadata() }
        }
    }

    // MARK: - Search

    // Full-text cask search via the casks_fts index. Each whitespace-separated
    // term becomes a quoted literal prefix term, ANDed together ("vis stu" finds
    // "Visual Studio Code"); excludes deprecated rows, caps results at 50. Empty
    // query returns nothing.
    func searchCasks(query: String) async throws -> [CaskMetadata] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }

        // FTS5 MATCH treats `"`, `(`, `:`, `-`, OR/AND etc. as syntax, so a raw
        // `trimmed + "*"` blows up on inputs like `c++`, `node-red`, `a OR b`,
        // or a stray quote — the query throws and the caller silently falls back
        // to weaker local filtering. Quote EACH whitespace-separated token as its
        // own literal prefix term (doubling any embedded quote to escape it, with
        // the prefix `*` OUTSIDE the quote so it stays a prefix query), joined by
        // spaces so FTS5 ANDs them. This preserves multi-word AND-of-prefixes
        // matching — "editor code" still finds "Open-source code editor"
        // (non-adjacent) — while never producing a syntax error. (A single quoted
        // PHRASE would force the words to be adjacent and in order, missing those.)
        let terms = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty else { return [] }
        let pattern = terms
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " ")

        return try await dbQueue.read { db in
            let sql = """
                SELECT casks.* FROM casks
                JOIN casks_fts ON casks.rowid = casks_fts.rowid
                WHERE casks_fts MATCH ? AND casks.deprecated = 0 LIMIT 50
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [pattern])
            return rows.map { CaskRecord(row: $0).toCaskMetadata() }
        }
    }

    // MARK: - Install-count analytics

    // Writes the per-token install counts for one analytics window (30d/90d/365d)
    // onto the matching casks column. `period` is mapped to a column through a
    // whitelisted switch; an unrecognized period is a silent no-op.
    func updateInstallCounts(_ counts: [String: Int], period: String) async throws {
        let column: String
        switch period {
        case "30d": column = "installCount30d"
        case "90d": column = "installCount90d"
        case "365d": column = "installCount365d"
        default: return
        }

        try await dbQueue.write { db in
            for (token, count) in counts {
                // Column name is built from a whitelisted switch above,
                // so direct interpolation here is safe (no user input).
                let sql = "UPDATE casks SET \(column) = ? WHERE token = ?"
                try db.execute(sql: sql, arguments: [count, token])
            }
        }
    }

    // Formula analytics counterpart to updateInstallCounts. The formulas table
    // only tracks 30d installs and is keyed by `name` (not `token`), so this is
    // a separate method rather than a period switch.
    func updateFormulaInstallCounts(_ counts: [String: Int]) async throws {
        try await dbQueue.write { db in
            for (name, count) in counts {
                try db.execute(
                    sql: "UPDATE formulas SET installCount30d = ? WHERE name = ?",
                    arguments: [count, name]
                )
            }
        }
    }

    // MARK: - Favorites

    // Toggles a cask's favorite state. Writes to both places that track it: the
    // denormalized `isFavorite` flag on the cask row (cheap to read alongside
    // catalog data) AND the `favorites` table (the membership/ordering source of
    // truth that survives a catalog replace). Favoriting upserts a favorites row
    // with a timestamp; unfavoriting deletes it.
    func markFavorite(token: String, isFavorite: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE casks SET isFavorite = ? WHERE token = ?",
                arguments: [isFavorite, token]
            )
            if isFavorite {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO favorites (token, type, addedAt) VALUES (?, 'cask', ?)",
                    arguments: [token, Date().timeIntervalSince1970]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM favorites WHERE token = ?",
                    arguments: [token]
                )
            }
        }
    }

    // Returns the favorited casks, most-recently-added first. Joins the
    // favorites table (source of truth for membership + addedAt ordering)
    // against casks so we get full CaskMetadata back.
    func fetchFavorites() async throws -> [CaskMetadata] {
        try await dbQueue.read { db in
            let sql = """
                SELECT casks.* FROM casks
                JOIN favorites ON favorites.token = casks.token
                ORDER BY favorites.addedAt DESC
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.map { CaskRecord(row: $0).toCaskMetadata() }
        }
    }

    // Returns just the set of favorited tokens (cheap; used to seed the
    // in-memory favorite state on AppDataService at launch).
    func fetchFavoriteTokens() async throws -> Set<String> {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT token FROM favorites")
            return Set(rows.map { $0["token"] as String })
        }
    }

    // MARK: - Installed packages (cache)

    func fetchInstalled() async throws -> [InstalledPackage] {
        try await dbQueue.read { db in
            let records = try InstalledRecord.fetchAll(db)
            return records.map { $0.toInstalledPackage() }
        }
    }

    // Replaces the cached installed list outright (delete-all then re-insert) so
    // it exactly mirrors the latest `brew` scan — packages uninstalled outside
    // the app don't linger. This is the table's whole-table rebuild on refresh.
    func saveInstalled(_ packages: [InstalledPackage]) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM installedPackages")
            for package in packages {
                let record = InstalledRecord(package: package)
                try record.insert(db, onConflict: .replace)
            }
        }
    }

    // MARK: - Notes

    // Saves (or clears) the per-token user note. A note that trims to empty is
    // treated as a deletion so it drops out of fetchAllNotes rather than
    // lingering as a blank row.
    func saveNote(token: String, note: String) async throws {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try await dbQueue.write { db in
            if trimmed.isEmpty {
                // Empty note = delete the row, so it drops out of fetchAllNotes.
                try db.execute(
                    sql: "DELETE FROM userNotes WHERE token = ?",
                    arguments: [token]
                )
            } else {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO userNotes (token, note, updatedAt) VALUES (?, ?, ?)",
                    arguments: [token, trimmed, Date().timeIntervalSince1970]
                )
            }
        }
    }

    // Returns the saved note for a single token, or nil if none exists.
    func fetchNote(token: String) async throws -> String? {
        try await dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT note FROM userNotes WHERE token = ?",
                arguments: [token]
            )
            return row?["note"]
        }
    }

    // Returns every cask that has a non-empty note, joined to its catalog
    // metadata, most-recently-edited first. Used by NotesView. Returns the
    // full CaskMetadata (for displayName etc.) paired with the note text.
    func fetchAllNotes() async throws -> [(cask: CaskMetadata, note: String)] {
        try await dbQueue.read { db in
            let sql = """
                SELECT casks.*, userNotes.note AS userNote
                FROM userNotes
                JOIN casks ON casks.token = userNotes.token
                WHERE userNotes.note IS NOT NULL AND userNotes.note <> ''
                ORDER BY userNotes.updatedAt DESC
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.map { row in
                let note: String = row["userNote"] ?? ""
                return (cask: CaskRecord(row: row).toCaskMetadata(), note: note)
            }
        }
    }

    // MARK: - Refresh bookkeeping & metadata (appMetadata)

    // True when the catalog/data identified by `key` was last refreshed more
    // than `ttlHours` ago (or never). Backs the "should I re-fetch from the
    // network?" decision. Reads the "lastRefresh_<key>" appMetadata entry.
    func isDataStale(key: String, ttlHours: Double) async throws -> Bool {
        try await dbQueue.read { db in
            let sql = "SELECT value FROM appMetadata WHERE key = ?"
            let metaKey = "lastRefresh_\(key)"
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [metaKey]) else {
                return true
            }
            let value: String = row["value"] ?? ""
            guard let timestamp = Double(value) else { return true }
            let now = Date().timeIntervalSince1970
            return (now - timestamp) > ttlHours * 3600
        }
    }

    func updateRefreshTimestamp(key: String) async throws {
        try await dbQueue.write { db in
            let keyStr = "lastRefresh_\(key)"
            let valueStr = "\(Date().timeIntervalSince1970)"
            try db.execute(
                sql: "INSERT OR REPLACE INTO appMetadata (key, value) VALUES (?, ?)",
                arguments: [keyStr, valueStr]
            )
        }
    }

    // Generic appMetadata key/value accessors (used for the Homebrew
    // ETag stored alongside lastRefresh_casks, etc.).
    func getMetadata(key: String) async throws -> String? {
        try await dbQueue.read { db in
            let sql = "SELECT value FROM appMetadata WHERE key = ?"
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [key]) else {
                return nil
            }
            let value: String? = row["value"]
            return value
        }
    }

    func setMetadata(key: String, value: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO appMetadata (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    // MARK: - Install history

    // Appends one event to the install-history log (install/uninstall/upgrade),
    // timestamped. Append-only; never updated or deleted here.
    func logInstallEvent(
        token: String, type: PackageType, action: String, version: String?
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO installHistory (token, type, action, version, timestamp) VALUES (?, ?, ?, ?, ?)",
                arguments: [token, type.rawValue, action, version, Date().timeIntervalSince1970]
            )
        }
    }

    // MARK: - Parked apps

    // Inserts/updates a park record for (token, type). Re-parking the same
    // package replaces the prior record (INSERT OR REPLACE on the composite
    // primary key), so changing the park type/duration just overwrites it.
    func park(
        token: String,
        type: PackageType,
        parkType: ParkType,
        parkedVersion: String?,
        expiresAt: Date?
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO parkedApps
                        (token, type, parkType, parkedAt, parkedVersion, expiresAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    token,
                    type.rawValue,
                    parkType.rawValue,
                    Date().timeIntervalSince1970,
                    parkedVersion,
                    expiresAt?.timeIntervalSince1970
                ]
            )
        }
    }

    // Removes a park record. No-op if the package wasn't parked.
    func unpark(token: String, type: PackageType) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM parkedApps WHERE token = ? AND type = ?",
                arguments: [token, type.rawValue]
            )
        }
    }

    // Returns every parked record (most-recently-parked first), decoded into
    // ParkedApp value types. Rows with an unrecognized parkType/type are
    // skipped defensively rather than crashing the read.
    func fetchParkedApps() async throws -> [ParkedApp] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM parkedApps ORDER BY parkedAt DESC"
            )
            return rows.compactMap { row -> ParkedApp? in
                let token: String = row["token"]
                guard let type = PackageType(rawValue: row["type"] ?? ""),
                      let parkType = ParkType(rawValue: row["parkType"] ?? "") else {
                    return nil
                }
                let parkedAtRaw: Double = row["parkedAt"] ?? 0
                let parkedVersion: String? = row["parkedVersion"]
                let expiresAtRaw: Double? = row["expiresAt"]
                return ParkedApp(
                    token: token,
                    type: type,
                    parkType: parkType,
                    parkedAt: Date(timeIntervalSince1970: parkedAtRaw),
                    parkedVersion: parkedVersion,
                    expiresAt: expiresAtRaw.map { Date(timeIntervalSince1970: $0) }
                )
            }
        }
    }

    // MARK: - Tags

    // Creates a new tag and returns it (with its freshly assigned rowid).
    // Name is stored trimmed; color/icon are stored as their raw tokens.
    @discardableResult
    func createTag(name: String, color: TagColor, icon: String) async throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await dbQueue.write { db in
            // Reuse an existing tag with the same name (case-insensitive) instead
            // of inserting a duplicate. The tags table has no UNIQUE constraint
            // on name, so without this check typing the same name twice would
            // create two distinct rows — the user would see the tag duplicated.
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT id, name, color, icon FROM tags WHERE name = ? COLLATE NOCASE LIMIT 1",
                arguments: [trimmed]
            ) {
                let id: Int64 = existing["id"]
                let existingName: String = existing["name"] ?? trimmed
                let existingColor = TagColor(rawValue: existing["color"] ?? "") ?? color
                let existingIcon: String = existing["icon"] ?? icon
                return Tag(id: id, name: existingName, color: existingColor, icon: existingIcon, itemCount: 0)
            }
            try db.execute(
                sql: "INSERT INTO tags (name, color, icon, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [trimmed, color.rawValue, icon, Date().timeIntervalSince1970]
            )
            let id = db.lastInsertedRowID
            return Tag(id: id, name: trimmed, color: color, icon: icon, itemCount: 0)
        }
    }

    // Updates an existing tag's name/color/icon in place. The id is stable, so
    // all existing memberships in itemTags are preserved.
    func updateTag(id: Int64, name: String, color: TagColor, icon: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tags SET name = ?, color = ?, icon = ? WHERE id = ?",
                arguments: [trimmed, color.rawValue, icon, id]
            )
        }
    }

    // Deletes a tag and all of its memberships. ON DELETE CASCADE handles the
    // join rows when foreign keys are enabled (GRDB's default); we delete from
    // itemTags explicitly too so this is correct even if FKs are ever off.
    func deleteTag(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM itemTags WHERE tagId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [id])
        }
    }

    // Returns every tag, alphabetised by name, each carrying its current item
    // count (across both casks and formulae) via a LEFT JOIN so zero-item tags
    // still appear. Used by the Tags section of the Notes & Tags view and by
    // the tag picker.
    func fetchTags() async throws -> [Tag] {
        try await dbQueue.read { db in
            let sql = """
                SELECT tags.id AS id, tags.name AS name, tags.color AS color,
                       tags.icon AS icon, COUNT(itemTags.token) AS itemCount
                FROM tags
                LEFT JOIN itemTags ON itemTags.tagId = tags.id
                GROUP BY tags.id
                ORDER BY tags.name COLLATE NOCASE ASC
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.compactMap { row -> Tag? in
                let id: Int64 = row["id"]
                let name: String = row["name"] ?? ""
                let color = TagColor(rawValue: row["color"] ?? "") ?? .default
                let icon: String = row["icon"] ?? TagIcon.default
                let count: Int = row["itemCount"] ?? 0
                return Tag(id: id, name: name, color: color, icon: icon, itemCount: count)
            }
        }
    }

    // Attaches a tag to a package. Idempotent: re-adding the same (tag, token,
    // type) is a no-op thanks to INSERT OR IGNORE on the composite primary key.
    func addTag(tagId: Int64, token: String, type: PackageType) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO itemTags (tagId, token, type, addedAt)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [tagId, token, type.rawValue, Date().timeIntervalSince1970]
            )
        }
    }

    // Detaches a tag from a package. No-op if it wasn't attached.
    func removeTag(tagId: Int64, token: String, type: PackageType) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM itemTags WHERE tagId = ? AND token = ? AND type = ?",
                arguments: [tagId, token, type.rawValue]
            )
        }
    }

    // Returns the tags carried by one package (token, type), alphabetised.
    // itemCount is left at 0 here — callers that need counts use fetchTags().
    func fetchTags(forToken token: String, type: PackageType) async throws -> [Tag] {
        try await dbQueue.read { db in
            let sql = """
                SELECT tags.id AS id, tags.name AS name, tags.color AS color,
                       tags.icon AS icon
                FROM tags
                JOIN itemTags ON itemTags.tagId = tags.id
                WHERE itemTags.token = ? AND itemTags.type = ?
                ORDER BY tags.name COLLATE NOCASE ASC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [token, type.rawValue])
            return rows.compactMap { row -> Tag? in
                let id: Int64 = row["id"]
                let name: String = row["name"] ?? ""
                let color = TagColor(rawValue: row["color"] ?? "") ?? .default
                let icon: String = row["icon"] ?? TagIcon.default
                return Tag(id: id, name: name, color: color, icon: icon)
            }
        }
    }

    // Returns the (token, type) references of every package carrying a tag.
    // The caller (AppDataService) resolves these against its in-memory cask and
    // formula catalogs, since a single SQL join can't reach both tables.
    func fetchTaggedItems(tagId: Int64) async throws -> [TaggedItemRef] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT token, type FROM itemTags WHERE tagId = ? ORDER BY addedAt DESC",
                arguments: [tagId]
            )
            return rows.compactMap { row -> TaggedItemRef? in
                let token: String = row["token"] ?? ""
                guard !token.isEmpty,
                      let type = PackageType(rawValue: row["type"] ?? "") else {
                    return nil
                }
                return TaggedItemRef(token: token, type: type)
            }
        }
    }
}
