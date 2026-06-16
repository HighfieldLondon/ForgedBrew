import SwiftUI

// MARK: - Shared action-button palette
//
// One source of truth for the colors used on the app's primary action buttons
// (Install / Update / Installed-remove / destructive Clear-Cache, etc.). These
// are deliberately a touch desaturated and slightly darker than the system
// `.red` / `.orange` so prominent (white-on-fill) buttons and their hover
// states read as confident rather than fluorescent / harsh on the eyes.
//
// Prominent buttons fill with the base color and darken slightly on hover
// (see DetailActionButton). Use `.hover` only where a view manages its own
// background instead of going through DetailActionButton.
nonisolated enum ActionColors {
    /// Install — muted sage green. Deliberately softer / more desaturated than
    /// the settled `installed` green so the call-to-action reads as calm rather
    /// than the previous fluorescent blue.
    static let install = Color(red: 0.30, green: 0.55, blue: 0.40)

    /// Update / outdated — warm amber. Deeper and more muted than system
    /// `.orange` (which is ~1.0/0.58/0.0) so its solid/hover fill reads as a
    /// calm amber rather than a fluorescent orange.
    static let update = Color(red: 0.80, green: 0.50, blue: 0.20)

    /// Installed (tap to remove) — settled green.
    static let installed = Color(red: 0.18, green: 0.62, blue: 0.36)

    /// Destructive (Clear Cache, uninstall confirmations) — muted brick red,
    /// not the bright system `.red`.
    static let destructive = Color(red: 0.80, green: 0.28, blue: 0.26)

    /// Homebrew brown — kept for the "Homebrew page" / brand actions.
    static let homebrew = Color(red: 0.45, green: 0.27, blue: 0.16)

    /// GitHub — near-black slate, matching GitHub's dark brand mark.
    static let github = Color(red: 0.14, green: 0.16, blue: 0.18)

    /// Adopt — Homebrew brown. The "bring this under Homebrew" action wears the
    /// brand's own brown so it reads as a Homebrew gesture (matching the
    /// Homebrew-page brown), distinct from the accent-blue Open App and the red
    /// Uninstall. Rendered as a solid brown chip with `adoptText` orange.
    static let adopt = Color(red: 0.40, green: 0.26, blue: 0.16)

    /// Adopt label — a warm, muted orange tuned to sit on the brown `adopt`
    /// chip without glaring. Lighter and a touch desaturated vs system
    /// `.orange` so it reads as a friendly Homebrew amber on brown, with
    /// comfortable contrast.
    static let adoptText = Color(red: 0.95, green: 0.66, blue: 0.36)

    /// Website — the same medium blue as the detail tab’s Homepage button, so
    /// the “Website” pill reads clearly (white label on a calm blue) instead
    /// of the hard-to-read light-grey fill it used before.
    static let website = Color(red: 0.30, green: 0.62, blue: 0.96)
}
