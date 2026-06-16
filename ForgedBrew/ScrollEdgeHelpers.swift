//
//  ScrollEdgeHelpers.swift
//  ForgedBrew
//
//  Shared helper to tame the macOS 26 "scroll edge effect" — the automatic
//  blur/fade applied to content that scrolls under the system toolbar / safe
//  area. Left at its default (.automatic), that effect ghosts the top row of
//  browse-grid cards and the icon/title at the top of a detail card (the
//  translucent "opaque bar" the user reported).
//
//  `.scrollEdgeEffectStyle(.hard, for:)` replaces the diffuse fade with a crisp
//  cutoff (a thin dividing line, no ghosting). The API is macOS 26.0+ only and
//  the app deploys to macOS 15.6, so every use must be guarded by
//  `#available`. This wrapper does that once so call sites stay clean and the
//  type-changing modifier doesn't leak into ViewBuilder availability branches.
//

import SwiftUI

extension View {
    /// Applies a hard (non-ghosting) scroll edge effect on macOS 26+, and is a
    /// no-op on earlier OS versions where the API doesn't exist.
    ///
    /// - Parameter edges: which edges to harden. Defaults to `.all`.
    func hardScrollEdge(_ edges: HardScrollEdge.Edges = .all) -> some View {
        modifier(HardScrollEdge(edges: edges))
    }
}

/// ViewModifier wrapper so the availability check and the type change introduced
/// by `.scrollEdgeEffectStyle` are contained in one place. Using a modifier
/// (rather than an inline `if #available` returning `some View`) keeps the
/// erased return type stable and avoids opaque-type mismatch errors.
struct HardScrollEdge: ViewModifier {
    /// Mirrors the subset of edges we use, mapped to the system enum at apply
    /// time so the type isn't referenced on older OSes.
    enum Edges {
        case top
        case all
    }

    let edges: Edges

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            switch edges {
            case .top:
                content.scrollEdgeEffectStyle(.hard, for: .top)
            case .all:
                content.scrollEdgeEffectStyle(.hard, for: .all)
            }
        } else {
            content
        }
    }
}
