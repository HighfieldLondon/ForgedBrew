//
//  DiskFootprint.swift
//  ForgedBrew
//
//  A breakdown of where Homebrew's disk space actually goes. We measure four
//  components:
//
//    • Apps      (`<prefix>/Caskroom`)        — your installed cask apps. This is
//                                               the real size Homebrew keeps for
//                                               each installed cask; it IS the
//                                               apps, so it can't be reclaimed.
//                                               (Earlier builds listed this as a
//                                               separate "Caskroom" row and a
//                                               near-zero "Apps" row; they are
//                                               the same thing, now merged.)
//    • Formulae  (`brew --cellar`)            — installed formulae, including any
//                                               stale old versions.
//    • Cache     (`brew --cache`)             — downloaded bottles + source
//                                               archives (safe to clear anytime).
//    • Taps      (`brew --repository`/Library/Taps) — the git clones of the
//                                               formula/cask repositories.
//
//  The Disk Usage sheet shows each component with a proportional bar plus the
//  combined total, so the user can see at a glance what's eating space and which
//  parts are reclaimable.
//

import Foundation

// One measured location in the Homebrew footprint. `nonisolated` + Sendable so
// it crosses the actor boundary from BrewCLIService up to the @MainActor UI.
nonisolated struct DiskFootprintComponent: Identifiable, Sendable, Hashable {
    // Stable identity for ForEach — the kind is unique within a footprint.
    var id: String { kind.rawValue }

    let kind: Kind
    // Measured size in bytes. 0 when the location is empty or couldn't be read.
    let bytes: Int64
    // Absolute path measured, shown in the row (monospaced) and used for Reveal
    // in Finder. nil when the path couldn't be resolved (e.g. Apps, which spans
    // many bundles rather than a single directory).
    let path: String?

    // The four footprint locations, each with display metadata.
    nonisolated enum Kind: String, Sendable, Hashable, CaseIterable {
        case apps
        case cellar
        case cache
        case taps

        var title: String {
            switch self {
            case .apps:     return "Apps"
            case .cellar:   return "Formulae"
            case .cache:    return "Download Cache"
            case .taps:     return "Taps (Repositories)"
            }
        }

        var systemImage: String {
            switch self {
            case .apps:     return "app.badge"
            case .cellar:   return "shippingbox"
            case .cache:    return "arrow.down.circle"
            case .taps:     return "books.vertical"
            }
        }

        // A short note on what this is and whether it's safe to clear.
        var explanation: String {
            switch self {
            case .apps:
                return "Your installed cask apps — what Homebrew keeps in the Caskroom for each one. These are the apps themselves and can't be reclaimed."
            case .cellar:
                return "Formulae installed in the Cellar, including any old versions left behind."
            case .cache:
                return "Downloaded bottles and source archives. Safe to clear anytime — Homebrew re-downloads as needed."
            case .taps:
                return "Git clones of the formula and cask repositories Homebrew reads from."
            }
        }

        // Whether Normal/Deep Clean can reclaim this component. Only the
        // download cache is freed by `brew cleanup` (Deep also scrubs the latest
        // versions). The Caskroom holds staged installers for *currently
        // installed* casks, which Homebrew never deletes, so it is NOT counted
        // as reclaimable here. Apps and the Cellar need targeted uninstall, and
        // Taps are required to function.
        var isReclaimableByCleanup: Bool {
            self == .cache
        }

        // Bar color — distinct, accessible hues (not color-alone; rows also
        // carry an icon + label).
        var tint: ColorToken {
            switch self {
            case .apps:     return .blue
            case .cellar:   return .teal
            case .cache:    return .orange
            case .taps:     return .gray
            }
        }
    }

    // Human-readable size like "328 MB". Always returns a value ("Zero KB" for 0).
    var sizeString: String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}

// A tiny indirection so the model stays free of SwiftUI. The view maps these
// tokens to concrete Colors. Keeps DiskFootprint.swift importing only Foundation.
nonisolated enum ColorToken: Sendable, Hashable {
    case blue
    case teal
    case purple
    case orange
    case gray
    case green
    case red
    case yellow
}

// The whole footprint: the components plus convenience totals. Precomputed so
// the UI doesn't re-sum on each redraw.
nonisolated struct DiskFootprint: Sendable, Hashable {
    let components: [DiskFootprintComponent]

    var totalBytes: Int64 {
        components.reduce(0) { $0 + $1.bytes }
    }

    var totalString: String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: totalBytes)
    }

    // Bytes a cleanup could reclaim (the download cache only).
    var reclaimableBytes: Int64 {
        components.filter { $0.kind.isReclaimableByCleanup }.reduce(0) { $0 + $1.bytes }
    }

    var reclaimableString: String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: reclaimableBytes)
    }

    // Fraction (0…1) of the total represented by a component, for the bar width.
    // Returns 0 when the total is 0 to avoid division by zero.
    func fraction(of component: DiskFootprintComponent) -> Double {
        guard totalBytes > 0 else { return 0 }
        return Double(component.bytes) / Double(totalBytes)
    }

    var isEmpty: Bool { totalBytes == 0 }

    static let empty = DiskFootprint(components: [])
}
