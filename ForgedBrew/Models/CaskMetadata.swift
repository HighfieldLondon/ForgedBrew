import Foundation

nonisolated enum CaskCategory: String, CaseIterable, Codable, Sendable {
    // Display order (matches the sidebar + top category chip bar, since both
    // iterate `allCases`). Sorted roughly by size/importance, with `other`
    // near the end and `fonts` always LAST (least important, very numerous).
    case mediaAndCreative
    case developerTools
    case macosUtilities
    case productivity
    case hardwareAndDrivers
    case internetAndBrowsers
    case fileManagement
    case privacyAndSecurity
    case gamesAndEmulators
    case aiAndML
    case cloudAndDevOps
    case scienceAndData
    case financeAndCrypto
    case databases
    case virtualizationAndRemote
    case networking
    case terminalAndShell
    case educationAndReference
    case other
    case fonts

    var displayName: String {
        switch self {
        case .fonts: return "Fonts"
        case .mediaAndCreative: return "Media & Creative"
        case .developerTools: return "Developer Tools"
        case .macosUtilities: return "macOS Utilities"
        case .productivity: return "Productivity"
        case .hardwareAndDrivers: return "Hardware & Drivers"
        case .internetAndBrowsers: return "Internet & Browsers"
        case .fileManagement: return "File Management"
        case .privacyAndSecurity: return "Privacy & Security"
        case .gamesAndEmulators: return "Games & Emulators"
        case .aiAndML: return "AI & ML"
        case .cloudAndDevOps: return "Cloud & DevOps"
        case .scienceAndData: return "Science & Data"
        case .financeAndCrypto: return "Finance & Crypto"
        case .databases: return "Databases"
        case .virtualizationAndRemote: return "Virtualization & Remote"
        case .networking: return "Networking"
        case .terminalAndShell: return "Terminal & Shell"
        case .educationAndReference: return "Education & Reference"
        case .other: return "Other"
        }
    }

    var sfSymbol: String {
        switch self {
        case .fonts: return "textformat"
        case .mediaAndCreative: return "photo"
        case .developerTools: return "hammer"
        case .macosUtilities: return "gearshape"
        case .productivity: return "checkmark.circle"
        case .hardwareAndDrivers: return "cpu"
        case .internetAndBrowsers: return "globe"
        case .fileManagement: return "folder"
        case .privacyAndSecurity: return "lock.shield"
        case .gamesAndEmulators: return "gamecontroller"
        case .aiAndML: return "brain"
        case .cloudAndDevOps: return "cloud"
        case .scienceAndData: return "chart.bar"
        case .financeAndCrypto: return "dollarsign.circle"
        case .databases: return "cylinder"
        case .virtualizationAndRemote: return "display.2"
        case .networking: return "network"
        case .terminalAndShell: return "terminal"
        case .educationAndReference: return "book"
        case .other: return "ellipsis.circle"
        }
    }
}

nonisolated struct CaskMacOSRequirement: Codable, Sendable {
    let greaterThanOrEqualTo: [String]?

    enum CodingKeys: String, CodingKey {
        case greaterThanOrEqualTo = ">="
    }
}

nonisolated struct CaskDependsOn: Codable, Sendable {
    let macos: CaskMacOSRequirement?
    let cask: [String]?
}

nonisolated struct CaskMetadata: Codable, Sendable, Identifiable, Hashable {
    let token: String
    let name: [String]
    let desc: String?
    let homepage: String?
    // The cask's download/artifact URL (formulae JSON `url`). Often a GitHub
    // releases URL even when the homepage is a vendor site, so it's a strong
    // secondary signal for recovering the source repo (see githubURL).
    let downloadURL: String?
    let version: String?
    let autoUpdates: Bool?
    let deprecated: Bool
    let tapGitHead: String?
    let dependsOn: CaskDependsOn?
    let rubySourcePath: String?
    let installCount30d: Int
    // 90-day install count (the "3-Month Trend" sort signal). Like the 30d
    // count it is populated from Homebrew analytics and persisted in the DB;
    // defaults to 0 when absent so the API decode path stays safe.
    let installCount90d: Int
    // 365-day install count (the "Top Past Year" sort signal). Populated from
    // Homebrew analytics and persisted in the DB; defaults to 0 when absent.
    let installCount365d: Int

    // Runtime-only: a real SPDX license (e.g. "MIT", "GPL-3.0") resolved from
    // GitHub for the ~11% of casks with a GitHub repo, stamped on from the
    // persisted githubMeta cache when the catalog loads. NOT part of the
    // Homebrew JSON payload, so it is deliberately excluded from Codable
    // (decodes to nil, never encoded). nil means "license unknown".
    var cachedLicense: String? = nil

    enum CodingKeys: String, CodingKey {
        case token
        case name
        case desc
        case homepage
        case downloadURL = "url"
        case version
        case autoUpdates = "auto_updates"
        case deprecated
        case tapGitHead = "tap_git_head"
        case dependsOn = "depends_on"
        case rubySourcePath = "ruby_source_path"
        case installCount30d = "install_count_30d"
        case installCount90d = "install_count_90d"
        case installCount365d = "install_count_365d"
    }

    init(
        token: String,
        name: [String],
        desc: String? = nil,
        homepage: String? = nil,
        downloadURL: String? = nil,
        version: String? = nil,
        autoUpdates: Bool? = nil,
        deprecated: Bool = false,
        tapGitHead: String? = nil,
        dependsOn: CaskDependsOn? = nil,
        rubySourcePath: String? = nil,
        installCount30d: Int = 0,
        installCount90d: Int = 0,
        installCount365d: Int = 0,
        cachedLicense: String? = nil
    ) {
        self.token = token
        self.name = name
        self.desc = desc
        self.homepage = homepage
        self.downloadURL = downloadURL
        self.version = version
        self.autoUpdates = autoUpdates
        self.deprecated = deprecated
        self.tapGitHead = tapGitHead
        self.dependsOn = dependsOn
        self.rubySourcePath = rubySourcePath
        self.installCount30d = installCount30d
        self.installCount90d = installCount90d
        self.installCount365d = installCount365d
        self.cachedLicense = cachedLicense
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try container.decode(String.self, forKey: .token)
        self.name = try container.decode([String].self, forKey: .name)
        self.desc = try container.decodeIfPresent(String.self, forKey: .desc)
        self.homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        self.downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
        self.version = try container.decodeIfPresent(String.self, forKey: .version)
        self.autoUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoUpdates)
        self.deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated) ?? false
        self.tapGitHead = try container.decodeIfPresent(String.self, forKey: .tapGitHead)
        self.dependsOn = try container.decodeIfPresent(CaskDependsOn.self, forKey: .dependsOn)
        self.rubySourcePath = try container.decodeIfPresent(String.self, forKey: .rubySourcePath)
        self.installCount30d = try container.decodeIfPresent(Int.self, forKey: .installCount30d) ?? 0
        self.installCount90d = try container.decodeIfPresent(Int.self, forKey: .installCount90d) ?? 0
        self.installCount365d = try container.decodeIfPresent(Int.self, forKey: .installCount365d) ?? 0
        self.cachedLicense = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(desc, forKey: .desc)
        try container.encodeIfPresent(homepage, forKey: .homepage)
        try container.encodeIfPresent(downloadURL, forKey: .downloadURL)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(autoUpdates, forKey: .autoUpdates)
        try container.encode(deprecated, forKey: .deprecated)
        try container.encodeIfPresent(tapGitHead, forKey: .tapGitHead)
        try container.encodeIfPresent(dependsOn, forKey: .dependsOn)
        try container.encodeIfPresent(rubySourcePath, forKey: .rubySourcePath)
        try container.encode(installCount30d, forKey: .installCount30d)
        try container.encode(installCount90d, forKey: .installCount90d)
        try container.encode(installCount365d, forKey: .installCount365d)
    }

    var id: String { token }

    var displayName: String {
        name.first ?? token
    }

    var githubURL: URL? {
        // Prefer the homepage when it points at github.com; otherwise recover
        // the source repo from the download URL, which is frequently a GitHub
        // releases URL (e.g. github.com/owner/repo/releases/download/...) even
        // when the homepage is the vendor's own site. Sampling the catalog,
        // this roughly triples GitHub repo coverage versus homepage-only.
        if let url = Self.extractGitHubRepo(from: homepage) { return url }
        return Self.extractGitHubRepo(from: downloadURL)
    }

    // Pulls a clean https://github.com/<owner>/<repo> URL out of any string
    // containing a github.com path. Strips a trailing ".git" and ignores the
    // tail (releases/download/..., /tree/..., etc.). Skips non-repo owners like
    // "downloads"/"raw"/"gist" hosts that aren't api/repo-bearing. nil when no
    // owner/repo pair can be recovered.
    static func extractGitHubRepo(from string: String?) -> URL? {
        guard let string, let range = string.lowercased().range(of: "github.com/") else { return nil }
        let afterHost = String(string[range.upperBound...])
        let components = afterHost.split(separator: "/", omittingEmptySubsequences: true).map { String($0) }
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)")
    }

    // GitHub's auto-generated Open Graph social-preview banner for this cask's
    // repo, when it has a github.com homepage. This is a plain CDN image
    // (opengraph.githubassets.com) — NOT a GitHub API call — so loading it costs
    // nothing against the 60/hr API rate limit. Used as the card thumbnail
    // source (Phase B). nil for the ~89% of casks without a GitHub repo.
    var socialPreviewURL: URL? {
        guard let repo = githubURL else { return nil }
        let parts = repo.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        return URL(string: "https://opengraph.githubassets.com/1/\(parts[0])/\(parts[1])")
    }

    // True when we have a credible open-source signal: the app is hosted on
    // GitHub (strong proxy) OR we resolved a real OSS SPDX license. This is the
    // honest definition powering the "Open Source" filter. nil license + no
    // GitHub repo => unknown, treated as NOT open source.
    var isLikelyOpenSource: Bool {
        if let lic = cachedLicense {
            return !LicenseFormatting.proprietaryMarkers.contains(lic.uppercased())
        }
        return githubURL != nil
    }

    // The human-friendly license *type* ("MIT", "Apache 2.0", "GPL 3.0", …)
    // when we have resolved a real SPDX license from GitHub, else nil. This is
    // the value to show wherever we want to surface the license type clearly.
    var licenseType: String? {
        LicenseFormatting.friendlyType(for: cachedLicense)
    }

    // True when we have NO credible license signal at all: no resolved SPDX
    // license and not hosted on GitHub. Callers use this to honestly label the
    // license as "Unknown" instead of hiding it.
    var isLicenseUnknown: Bool {
        licenseType == nil && githubURL == nil
    }

    // Text for the license badge on cards/detail. Order of honesty:
    //  1. A real resolved SPDX license, prettified ("MIT", "Apache 2.0", …).
    //  2. "Open Source" when hosted on GitHub but license not yet resolved.
    //  3. nil — we genuinely don't know; callers should show no badge.
    var licenseBadgeText: String? {
        if let type = licenseType { return type }
        if githubURL != nil { return "Open Source" }
        return nil
    }

    // Top-level category, delegated to the shared keyword classifier.
    var category: CaskCategory {
        CaskClassifier.classify(token: token, desc: desc, homepage: homepage).category
    }

    // Subcategory display name within `category` (e.g. "Video", "Editors & IDEs").
    var subcategory: String {
        CaskClassifier.classify(token: token, desc: desc, homepage: homepage).subcategory
    }

    static func == (lhs: CaskMetadata, rhs: CaskMetadata) -> Bool {
        lhs.token == rhs.token
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(token)
    }
}
