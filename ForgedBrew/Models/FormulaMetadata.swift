import Foundation

/// The `versions` object from the Homebrew formula JSON.
/// - `stable`: the current released version string (e.g. "1.2.3"); absent for
///   HEAD-only formulae.
/// - `head`: the version label for the development (HEAD) build, when the
///   formula supports `brew install --HEAD`. Only present on the single-formula
///   endpoint, not in the bulk catalog dump.
nonisolated struct FormulaVersions: Codable, Sendable {
    let stable: String?
    let head: String?
}

/// A single Homebrew formula (a CLI tool / library / runtime), decoded from
/// formulae.brew.sh JSON and also persisted in the local catalog cache.
/// Fields map directly to the Homebrew formula API; see `CodingKeys` for the
/// snake_case wire names. The cask counterpart is `CaskMetadata`.
nonisolated struct FormulaMetadata: Codable, Sendable, Identifiable, Hashable {
    /// Short formula token / CLI command (API `name`), e.g. "wget". Also the
    /// Identifiable id and the primary key used everywhere (notes, tags, install).
    let name: String
    /// Fully-qualified name including tap for non-core formulae (API `full_name`),
    /// e.g. "homebrew/core/wget". Equals `name` for core formulae.
    let fullName: String
    /// One-line human description curated by Homebrew (API `desc`). May be nil.
    let desc: String?
    /// Project homepage URL (API `homepage`). Drives the Homepage button, repo
    /// resolution, and screenshot/preview fallbacks.
    let homepage: String?
    /// Raw SPDX license expression from Homebrew (API `license`), e.g.
    /// "Apache-2.0". Normalized for display via `licenseType`.
    let license: String?
    /// Stable + HEAD version strings (API `versions`).
    let versions: FormulaVersions
    /// Runtime dependencies (API `dependencies`). Empty in the bulk catalog;
    /// populated by the single-formula enrichment fetch.
    let dependencies: [String]
    /// Build-only dependencies (API `build_dependencies`), needed to compile
    /// from source but not at runtime.
    let buildDependencies: [String]
    /// Homebrew has deprecated this formula (API `deprecated`): discouraged but
    /// still installable.
    let deprecated: Bool
    /// Homebrew has disabled this formula (API `disabled`): installing it fails.
    /// Outranks `deprecated` in the UI.
    let disabled: Bool
    /// 30-day install count from the Homebrew analytics feed (API
    /// `install_count_30d`). Not part of the formula JSON itself — merged in
    /// separately — so it defaults to 0 when absent. Drives the popularity sort.
    let installCount30d: Int

    var id: String { name }

    // The human-friendly license *type* ("MIT", "Apache 2.0", "GPL 3.0", …),
    // normalized from the raw SPDX string Homebrew ships in the formula JSON.
    // nil when the license is missing or unknown so callers can label it
    // "Unknown" rather than printing a raw/empty token. (#4 license clarity)
    var licenseType: String? {
        LicenseFormatting.friendlyType(for: license)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case desc
        case homepage
        case license
        case versions
        case dependencies
        case buildDependencies = "build_dependencies"
        case deprecated
        case disabled
        case installCount30d = "install_count_30d"
    }

    // Memberwise initializer used when reconstructing a formula from the local
    // database (and anywhere the decoder isn't involved). The Homebrew
    // formula.json doesn't carry analytics at the top level, so installCount30d
    // defaults to 0 and is populated separately from the analytics feed.
    init(
        name: String,
        fullName: String,
        desc: String? = nil,
        homepage: String? = nil,
        license: String? = nil,
        versions: FormulaVersions,
        dependencies: [String] = [],
        buildDependencies: [String] = [],
        deprecated: Bool = false,
        disabled: Bool = false,
        installCount30d: Int = 0
    ) {
        self.name = name
        self.fullName = fullName
        self.desc = desc
        self.homepage = homepage
        self.license = license
        self.versions = versions
        self.dependencies = dependencies
        self.buildDependencies = buildDependencies
        self.deprecated = deprecated
        self.disabled = disabled
        self.installCount30d = installCount30d
    }

    // Custom decoder so a partial/legacy record still decodes: only name,
    // fullName and versions are required; every other field tolerates absence
    // (decodeIfPresent) and falls back to a sensible empty/false/zero default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        fullName = try container.decode(String.self, forKey: .fullName)
        versions = try container.decode(FormulaVersions.self, forKey: .versions)
        desc = try container.decodeIfPresent(String.self, forKey: .desc)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated) ?? false
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        dependencies = try container.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        buildDependencies = try container.decodeIfPresent([String].self, forKey: .buildDependencies) ?? []
        installCount30d = try container.decodeIfPresent(Int.self, forKey: .installCount30d) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(fullName, forKey: .fullName)
        try container.encode(versions, forKey: .versions)
        try container.encodeIfPresent(desc, forKey: .desc)
        try container.encodeIfPresent(homepage, forKey: .homepage)
        try container.encodeIfPresent(license, forKey: .license)
        try container.encode(deprecated, forKey: .deprecated)
        try container.encode(disabled, forKey: .disabled)
        try container.encode(dependencies, forKey: .dependencies)
        try container.encode(buildDependencies, forKey: .buildDependencies)
        try container.encode(installCount30d, forKey: .installCount30d)
    }

    // Top-level category. Formulae all live under the single "Formulae" sidebar
    // category, so this is a constant — it exists for symmetry with
    // CaskMetadata.category and so call sites can treat both uniformly.
    var category: String { "Formulae" }

    // Subcategory display name (e.g. "Languages & Runtimes", "Databases"),
    // delegated to the formula-specific keyword classifier.
    var subcategory: String {
        FormulaClassifier.classify(name: name, desc: desc, homepage: homepage)
    }

    /// Version string for display: the stable version, or "HEAD" for a
    /// HEAD-only formula that ships no stable release.
    var displayVersion: String {
        guard let stable = versions.stable, !stable.isEmpty else {
            return "HEAD"
        }
        return stable
    }

    /// The canonical GitHub repo URL when the homepage points at github.com —
    /// reduced to just the "github.com/owner/repo" root (dropping any deeper
    /// path). nil for non-GitHub homepages. Used to badge OSS formulae and as
    /// the starting point for README / license / repo resolution.
    var githubURL: URL? {
        guard let homepage = homepage, homepage.contains("github.com") else {
            return nil
        }
        guard let url = URL(string: homepage) else {
            return nil
        }
        // Keep only the first two path components (owner + repo); anything
        // deeper (wiki, blob, releases, …) is discarded.
        let components = url.path.split(separator: "/").map(String.init)
        guard components.count >= 2 else {
            return nil
        }
        return URL(string: "https://github.com/\(components[0])/\(components[1])")
    }

    // Identity is by `name` alone (the unique formula token), so two records
    // for the same formula compare equal and hash alike even if enrichment has
    // populated different secondary fields on one of them.

    static func == (lhs: FormulaMetadata, rhs: FormulaMetadata) -> Bool {
        lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
