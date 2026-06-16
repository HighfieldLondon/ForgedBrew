import SwiftUI

// MARK: - Shared pill action button style
//
// One source of truth for the app's small "pill" action buttons — the filled,
// white-on-color buttons that sit on the right of cards and rows (Scan, Review,
// Run, Clean Up, Clear Cache, Export / Import…, etc.).
//
// Standardizes the look AND the interaction so every button behaves the same:
//   • white semibold label, 14×6 padding, 8pt rounded fill
//   • fills with `tint` (defaults to the system accent color)
//   • darkens slightly on hover (the same gentle feedback the ForgedBrew Cache
//     button used) so the whole app feels consistent
//   • dips slightly + dims on press for a tactile click
//
// Usage — replace the old hand-rolled label + `.buttonStyle(.plain)` with:
//
//     Button("Review") { … }
//         .buttonStyle(PillActionButtonStyle())          // accent color
//     Button("Clear Cache") { … }
//         .buttonStyle(PillActionButtonStyle(tint: ActionColors.installed))
//
// The style owns the padding/fill/text, so the call site only supplies a plain
// title (or any label) — no manual font/padding/background needed.
struct PillActionButtonStyle: ButtonStyle {
    // Fill color. Defaults to the system accent so most buttons match without
    // having to pass anything; pass a custom tint for special cases.
    var tint: Color = .accentColor
    // Corner radius — a couple of compact rows use 7; everything else uses 8.
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        PillActionButton(configuration: configuration,
                         tint: tint,
                         cornerRadius: cornerRadius)
    }

    // Inner view so we can hold @State for hover (ButtonStyle itself can't).
    private struct PillActionButton: View {
        let configuration: Configuration
        let tint: Color
        let cornerRadius: CGFloat
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            // Darken on hover OR press; dim when disabled.
            let dimmed = configuration.isPressed || isHovering
            let opacity: Double = !isEnabled ? 0.45 : (dimmed ? 0.85 : 1.0)
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(tint.opacity(opacity),
                            in: RoundedRectangle(cornerRadius: cornerRadius))
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
