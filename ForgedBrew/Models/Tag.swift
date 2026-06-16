//
//  Tag.swift
//  ForgedBrew
//
//  User-defined tags for organizing packages, per our design outline for package
//  tagging. A tag has a name, a color, and an SF Symbol icon. Tags can be
//  attached to both casks (apps) and formulae (command-line tools); membership
//  is stored as (token, type) pairs so a single tag can span both.
//
//  This model is deliberately free of SwiftUI: like the rest of Models/, it
//  imports only Foundation and exposes a color/icon as plain tokens that the
//  view layer maps to concrete SwiftUI values. It is `nonisolated` + Sendable so
//  it can cross the actor boundary from the DatabaseManager actor up to the
//  @MainActor UI under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
//

import Foundation

// A single user-defined tag.
nonisolated struct Tag: Identifiable, Sendable, Hashable {
    let id: Int64            // SQLite rowid; stable across renames/recolors
    var name: String
    var color: TagColor
    var icon: String         // SF Symbol name, e.g. "tag.fill"

    // Count of packages carrying this tag. Populated by the fetch that lists
    // tags for the sidebar/Tags view; 0 elsewhere. Not persisted.
    var itemCount: Int = 0
}

// The palette a tag's color is chosen from. A closed set keeps the picker simple
// and the stored value stable (we persist the raw string). The view maps each
// case to a concrete Color — the model stays SwiftUI-free.
nonisolated enum TagColor: String, Sendable, Hashable, CaseIterable, Codable {
    case blue
    case teal
    case green
    case yellow
    case orange
    case red
    case pink
    case purple
    case indigo
    case gray

    // A sensible default for newly created tags before the user picks.
    static let `default`: TagColor = .blue
}

// The SF Symbols a tag's icon is chosen from. A curated set so the icon picker
// is a tidy grid rather than an open-ended search. All are present on macOS 12+.
nonisolated enum TagIcon {
    // The default icon for a new tag.
    static let `default` = "tag.fill"

    // Curated, project/purpose-oriented glyphs for the picker grid.
    static let choices: [String] = [
        "tag.fill",
        "star.fill",
        "flag.fill",
        "bookmark.fill",
        "folder.fill",
        "briefcase.fill",
        "hammer.fill",
        "wrench.and.screwdriver.fill",
        "paintbrush.fill",
        "terminal.fill",
        "chevron.left.forwardslash.chevron.right",
        "cube.fill",
        "shippingbox.fill",
        "gamecontroller.fill",
        "music.note",
        "photo.fill",
        "film.fill",
        "globe",
        "lock.fill",
        "bolt.fill",
        "heart.fill",
        "leaf.fill",
        "flame.fill",
        "graduationcap.fill"
    ]
}

// A lightweight membership row: which (token, type) carries a tag. Used to
// resolve tag membership against the in-memory cask/formula catalogs in
// AppDataService (which knows both), since a single SQL join can't reach both
// the casks and formulas tables at once.
nonisolated struct TaggedItemRef: Sendable, Hashable {
    let token: String
    let type: PackageType
}

// A tag membership resolved against the in-memory catalogs into something the
// UI can render directly: the package's token, a human-friendly display name,
// its description, and whether it's a cask or formula. Built by AppDataService
// from TaggedItemRefs so the Tags view doesn't have to touch the raw catalogs.
nonisolated struct TaggedPackage: Identifiable, Sendable, Hashable {
    let token: String
    let type: PackageType
    let displayName: String
    let desc: String?

    // token+type uniquely identifies a package across both catalogs.
    var id: String { "\(type.rawValue):\(token)" }
}
