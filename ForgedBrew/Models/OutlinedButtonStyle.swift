import SwiftUI

// MARK: - Outlined controls for clear visibility in BOTH light and dark mode
//
// The app's light theme made many controls hard to see: bordered/borderless
// buttons and segmented selectors relied on very faint translucent fills with
// little or no border, so on a white background they nearly vanished. These
// helpers give every such control a clear, appearance-aware outline plus a
// readable fill, and make a SELECTED state stand out boldly.
//
// Use:
//   Button("Rescan") { … }
//       .buttonStyle(OutlinedButtonStyle())            // replaces .bordered
//   Button(role: .destructive) { … } label: { … }
//       .buttonStyle(OutlinedButtonStyle())            // picks up the red role
//
//   // Segmented / toggle-style selectors:
//   someLabel.selectionChip(isSelected: isOn)

// A bordered button that stays clearly visible in light mode. Neutral by
// default; a `.destructive` role tints it red. The outline is stronger in light
// mode (where faint fills disappear on white) and softer in dark mode.
struct OutlinedButtonStyle: ButtonStyle {
    // Optional explicit tint. When nil, neutral (uses primary) unless the
    // button's role is destructive, which tints red.
    var tint: Color? = nil
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        OutlinedButton(configuration: configuration,
                       tint: tint,
                       cornerRadius: cornerRadius)
    }

    private struct OutlinedButton: View {
        let configuration: Configuration
        let tint: Color?
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme
        @State private var isHovering = false

        // Resolved accent: explicit tint > destructive role red > neutral.
        private var accent: Color {
            if let tint { return tint }
            if configuration.role == .destructive {
                return Color(red: 0.80, green: 0.25, blue: 0.28)
            }
            return .primary
        }

        private var isLight: Bool { scheme == .light }

        // Border: clearly visible in light mode, softer in dark.
        private var borderColor: Color {
            let base = (tint == nil && configuration.role != .destructive)
                ? Color.primary
                : accent
            let o = isLight ? 0.35 : 0.30
            return base.opacity(o)
        }

        // Fill: subtle but readable; darkens a touch on hover/press.
        private var fillColor: Color {
            let pressed = configuration.isPressed || isHovering
            if tint == nil && configuration.role != .destructive {
                // Neutral button: light grey fill that reads on white.
                let o = isLight ? (pressed ? 0.12 : 0.06) : (pressed ? 0.22 : 0.14)
                return Color.primary.opacity(o)
            } else {
                let o = pressed ? 0.20 : 0.12
                return accent.opacity(o)
            }
        }

        private var labelColor: Color {
            if tint == nil && configuration.role != .destructive { return .primary }
            return accent
        }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? labelColor : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(fillColor, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .opacity(isEnabled ? 1.0 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
        }
    }
}

// MARK: - Selection chip

// A segmented-style selectable chip that reads clearly in light mode. Selected
// = bold solid accent fill with white label + accent border. Unselected = clear
// neutral outline with a faint fill, so it's always visibly a button.
private struct SelectionChip: ViewModifier {
    let isSelected: Bool
    var cornerRadius: CGFloat = 8
    @Environment(\.colorScheme) private var scheme

    private var isLight: Bool { scheme == .light }

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? Color.accentColor
                    : Color.primary.opacity(isLight ? 0.06 : 0.12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor
                            : Color.primary.opacity(isLight ? 0.30 : 0.28),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension View {
    // Apply a clearly-visible segmented selection chip look. `isSelected` drives
    // the bold accent-filled selected state.
    func selectionChip(isSelected: Bool, cornerRadius: CGFloat = 8) -> some View {
        modifier(SelectionChip(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}
