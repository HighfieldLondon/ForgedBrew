import Foundation

nonisolated struct FormulaVersions: Codable, Sendable {
    let stable: String?
    let head: String?
}

nonisolated struct FormulaMetadata: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let fullName: String
    let desc: String?
    let homepage: String?
    let license: String?
    let versions: FormulaVersions
    let dependencies: [String]
    let buildDependencies: [String]
    let deprecated: Bool
    let disabled: Bool
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

    var displayVersion: String {
        guard let stable = versions.stable, !stable.isEmpty else {
            return "HEAD"
        }
        return stable
    }

    var githubURL: URL? {
        guard let homepage = homepage, homepage.contains("github.com") else {
            return nil
        }
        guard let url = URL(string: homepage) else {
            return nil
        }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.count >= 2 else {
            return nil
        }
        return URL(string: "https://github.com/\(components[0])/\(components[1])")
    }

    static func == (lhs: FormulaMetadata, rhs: FormulaMetadata) -> Bool {
        lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
