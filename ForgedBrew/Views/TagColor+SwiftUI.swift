//
//  TagColor+SwiftUI.swift
//  ForgedBrew
//
//  Maps the SwiftUI-free TagColor model token to a concrete SwiftUI Color.
//  Lives in the view layer (imports SwiftUI) so Models/Tag.swift can stay
//  Foundation-only. Every tag UI surface (chips, picker, sheets, Tags view)
//  uses this single mapping so colors stay consistent.
//

import SwiftUI

nonisolated extension TagColor {
    /// The concrete color this token renders as. Uses system colors so the
    /// palette adapts to light/dark mode automatically.
    var color: Color {
        switch self {
        case .blue:   return .blue
        case .teal:   return .teal
        case .green:  return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red:    return .red
        case .pink:   return .pink
        case .purple: return .purple
        case .indigo: return .indigo
        case .gray:   return .gray
        }
    }

    /// A human-readable label for the color, used as the accessibility label
    /// in the color picker.
    var displayName: String {
        rawValue.capitalized
    }
}
