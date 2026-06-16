import Foundation

// 1. PackageType enum
nonisolated enum PackageType: String, Codable, CaseIterable, Sendable {
    case cask
    case formula
}

// 2. OutdatedInfo struct
nonisolated struct OutdatedInfo: Codable, Sendable {
    let currentVersion: String
    let installedVersion: String
    let pinned: Bool

    enum CodingKeys: String, CodingKey {
        case currentVersion = "current_version"
        case installedVersion = "installed_version"
        case pinned
    }
}

// 3. InstalledPackage struct
nonisolated struct InstalledPackage: Identifiable, Sendable {
    var id: String { "\(type.rawValue):\(token)" }
    let token: String
    let type: PackageType
    let installedVersion: String?
    let isOutdated: Bool
    let outdatedInfo: OutdatedInfo?
    // On-disk size of the installed artifact in bytes, when measured. For casks
    // this is the app bundle under /Applications; for formulae it's the Cellar
    // keg. nil means we haven't measured it (or the probe failed).
    let sizeBytes: Int?
    // When the package was installed or last updated, as reported by brew
    // (cask `installed_time`) or the formula's INSTALL_RECEIPT.json `time`.
    // nil means unknown.
    let installedDate: Date?
    // True when the user installed this deliberately (a top-level package),
    // false when Homebrew pulled it in only as a dependency of something else.
    // Casks have no dependency concept in brew, so they are always true.
    // Formulae derive this from the keg's `installed_on_request` flag.
    let installedOnRequest: Bool
    // Runtime dependencies (formulae this package needs to run), straight from
    // brew info JSON. Empty for casks and for formulae with no dependencies.
    // Shown inline in the Installed list under the name and Dependency tag.
    let dependencies: [String]

    init(
        token: String,
        type: PackageType,
        installedVersion: String?,
        isOutdated: Bool,
        outdatedInfo: OutdatedInfo?,
        sizeBytes: Int? = nil,
        installedDate: Date? = nil,
        installedOnRequest: Bool = true,
        dependencies: [String] = []
    ) {
        self.token = token
        self.type = type
        self.installedVersion = installedVersion
        self.isOutdated = isOutdated
        self.outdatedInfo = outdatedInfo
        self.sizeBytes = sizeBytes
        self.installedDate = installedDate
        self.installedOnRequest = installedOnRequest
        self.dependencies = dependencies
    }

    // Convenience: a formula that brew installed only as a dependency. Casks are
    // never dependency-only, so this is meaningful for formulae only.
    var isDependencyOnly: Bool { type == .formula && !installedOnRequest }

    // Human-readable size like "3.6 GB" / "148 MB", or nil when unmeasured.
    var sizeDisplay: String? {
        guard let bytes = sizeBytes else { return nil }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB, .useKB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: Int64(bytes))
    }
}

// 4. BrewOutdatedOutput struct (and its two nested info types)
//
// NOTE: the old `brew list --json` shapes (BrewListOutput / InstalledCaskInfo /
// InstalledFormulaInfo) were removed — installed packages are decoded from
// `brew info --installed --json=v2` via BrewInfoOutput (see below).

nonisolated struct OutdatedFormulaInfo: Codable, Sendable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String
    let pinned: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
        case pinned
    }
}

nonisolated struct OutdatedCaskInfo: Codable, Sendable {
    // The cask's token. IMPORTANT: `brew outdated --json=v2` keys this as
    // "name" for casks (NOT "token", which is what `brew info --json=v2` uses).
    // Decoding it from the wrong key made the WHOLE BrewOutdatedOutput decode
    // throw, so no cask was ever flagged outdated. We map the property from the
    // correct "name" key here.
    let token: String
    let installedVersions: [String]
    let currentVersion: String

    enum CodingKeys: String, CodingKey {
        case token = "name"
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }
}

nonisolated struct BrewOutdatedOutput: Codable, Sendable {
    let formulae: [OutdatedFormulaInfo]
    let casks: [OutdatedCaskInfo]
}


// MARK: - `brew info --installed --json=v2` shapes
//
// This is a DIFFERENT shape from `brew outdated --json=v2`. Casks expose a
// single `version` string; formulae expose an `installed` array of objects,
// each carrying its own `version`. We decode just the fields we need.

nonisolated struct BrewInfoCask: Codable, Sendable {
    let token: String
    let version: String?
    // Unix epoch seconds when the cask was installed/updated. Present in
    // `brew info --cask --json=v2`. Optional because older brew or partial
    // installs may omit it.
    let installedTime: Double?
    // Absolute path of the installed app bundle (the `app` artifact's `target`,
    // e.g. "/Applications/0 A.D..app"). Used to measure the real on-disk size,
    // since the Caskroom directory only holds metadata. nil when the cask has
    // no app artifact (e.g. pkg/binary-only casks).
    let appPath: String?
    // The cask homepage, e.g. "https://github.com/waydabber/BetterDisplay".
    let homepage: String?
    // The download URL for the cask artifact. Occasionally a GitHub releases
    // URL from which the source repo can be recovered.
    let url: String?

    enum CodingKeys: String, CodingKey {
        case token
        case version
        case installedTime = "installed_time"
        case artifacts
        case homepage
        case url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        installedTime = try c.decodeIfPresent(Double.self, forKey: .installedTime)
        homepage = try? c.decodeIfPresent(String.self, forKey: .homepage)
        url = try? c.decodeIfPresent(String.self, forKey: .url)

        // The artifacts array is heterogeneous: each element is an object with a
        // single descriptive key ("app", "zap", "binary", "uninstall", …). We
        // only want the `app` artifact's `target`, which brew normalizes to the
        // absolute install path. Decode loosely and pull the first app target.
        var resolvedAppPath: String? = nil
        if var artifactsArray = try? c.nestedUnkeyedContainer(forKey: .artifacts) {
            while !artifactsArray.isAtEnd {
                // Decode exactly ONE element per loop. AppArtifactEntry has only
                // optional fields, so it decodes any object element (its `app`
                // and `target` are nil for non-app shapes like `zap`). Non-object
                // elements (rare) fall through to the skip type. Either branch
                // consumes precisely one element, so the index always advances.
                if let entry = try? artifactsArray.decode(AppArtifactEntry.self) {
                    if resolvedAppPath == nil, entry.app != nil, let target = entry.target {
                        resolvedAppPath = target
                    }
                } else {
                    _ = try? artifactsArray.decode(AnyCodableSkip.self)
                }
            }
        }
        appPath = resolvedAppPath
    }

    // Encoding isn't used (these are decode-only CLI shapes), but Codable
    // conformance requires it. Emit just the stable fields.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(installedTime, forKey: .installedTime)
    }
}

// Decodes a cask artifact element ONLY when it carries an `app` array plus a
// `target` path (the installed app bundle). Other artifact shapes fail to
// decode (no `app` key) and are skipped by the caller.
nonisolated struct AppArtifactEntry: Codable, Sendable {
    let app: [String]?
    let target: String?
}

// A throwaway type used to advance the heterogeneous artifacts container past
// an element we don't care about. Decoding any single JSON value succeeds.
nonisolated struct AnyCodableSkip: Codable, Sendable {
    init(from decoder: Decoder) throws {
        // Consume one value of whatever shape without inspecting it.
        let c = try decoder.singleValueContainer()
        if (try? c.decode(Bool.self)) != nil { return }
        if (try? c.decode(Double.self)) != nil { return }
        if (try? c.decode(String.self)) != nil { return }
        if (try? c.decode([String: AnyCodableSkip].self)) != nil { return }
        if (try? c.decode([AnyCodableSkip].self)) != nil { return }
        // Null or unknown — nothing to consume.
    }
    func encode(to encoder: Encoder) throws {}
}

nonisolated struct BrewInfoFormulaInstalled: Codable, Sendable {
    let version: String?
    // Unix epoch seconds from this keg's INSTALL_RECEIPT.json, surfaced by
    // `brew info --installed --json=v2`. Used for the install/update date.
    let time: Double?
    // True when this keg was installed deliberately by the user (a top-level /
    // "leaf"-style package) rather than pulled in only as a dependency of
    // something else. Straight from the keg's INSTALL_RECEIPT.json. nil on
    // older brew that omits it; the caller defaults that to top-level.
    let installedOnRequest: Bool?

    enum CodingKeys: String, CodingKey {
        case version
        case time
        case installedOnRequest = "installed_on_request"
    }
}

nonisolated struct BrewInfoFormula: Codable, Sendable {
    let name: String
    let installed: [BrewInfoFormulaInstalled]
    // The stable upstream version string (versions.stable). Used by the
    // vulnerability scan to ask OSV about the installed version.
    let stableVersion: String?
    // The project homepage, e.g. "https://github.com/openssl/openssl".
    let homepage: String?
    // The stable source download URL (urls.stable.url), e.g. a GitHub release
    // or archive tarball. Often the best place to recover the GitHub repo.
    let stableURL: String?
    // Runtime dependencies for this formula, straight from brew info JSON.
    // Used to show the inline Depends on line in the Installed list without a
    // separate network call (the formulae catalog table stores these empty).
    let dependencies: [String]

    enum CodingKeys: String, CodingKey {
        case name, installed, versions, homepage, urls, dependencies
    }

    // Nested shapes we only need a couple of leaves from.
    private struct VersionsBlock: Codable { let stable: String? }
    private struct URLsBlock: Codable {
        let stable: StableURL?
        struct StableURL: Codable { let url: String? }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        installed = (try? c.decode([BrewInfoFormulaInstalled].self, forKey: .installed)) ?? []
        stableVersion = (try? c.decode(VersionsBlock.self, forKey: .versions))?.stable
        homepage = try? c.decodeIfPresent(String.self, forKey: .homepage)
        stableURL = (try? c.decode(URLsBlock.self, forKey: .urls))?.stable?.url
        dependencies = (try? c.decode([String].self, forKey: .dependencies)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(installed, forKey: .installed)
    }
}

nonisolated struct BrewInfoOutput: Codable, Sendable {
    let formulae: [BrewInfoFormula]
    let casks: [BrewInfoCask]
}
