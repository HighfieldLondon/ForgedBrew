import SwiftUI

// A consistent, clearly-a-button refresh control used in the header of each
// main page (Home, Installed, Homebrew Updates, Mac Store/Other Apps) and the
// Maintenance section/sheet headers.
//
// It reads as a real button — accent-tinted capsule with an icon + label — and
// is bigger than the old plain text affordance. While the work is in flight the
// caller disables it; SwiftUI dims the control (darker), and it returns to its
// brighter, fully-saturated look when the work finishes. That darken-while-
// working / lighten-when-done feedback is intentional and preserved here.
//
// Two sizes: .regular for the main page headers, and .compact for the denser
// Maintenance section/sheet headers (smaller titles) so the button sits more
// proportionally next to a ~15pt heading.
struct PageRefreshButton: View {
    enum Size {
        case regular, compact

        var font: CGFloat { self == .regular ? 13 : 11 }
        var hPadding: CGFloat { self == .regular ? 14 : 10 }
        var vPadding: CGFloat { self == .regular ? 7 : 4 }
    }

    // Button label, e.g. "Refresh" or "Rescan".
    let title: String
    // Whether work is currently running (used to disable + show the spinner).
    let isWorking: Bool
    // Visual size of the control.
    let size: Size
    // Tap handler.
    let action: () -> Void

    @State private var isHovering = false

    init(_ title: String = "Refresh",
         isWorking: Bool,
         size: Size = .regular,
         action: @escaping () -> Void) {
        self.title = title
        self.isWorking = isWorking
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: size.font, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: size.font, weight: .semibold))
            }
            .foregroundStyle(isHovering ? Color.white : Color.accentColor)
            .padding(.horizontal, size.hPadding)
            .padding(.vertical, size.vPadding)
            .background(
                isHovering
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(Color.accentColor.opacity(0.14)),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(isWorking)
    }
}

#Preview {
    VStack(spacing: 12) {
        PageRefreshButton(isWorking: false) {}
        PageRefreshButton(isWorking: true) {}
        PageRefreshButton("Rescan", isWorking: false) {}
        PageRefreshButton("Re-measure", isWorking: false, size: .compact) {}
        PageRefreshButton("Re-scan", isWorking: true, size: .compact) {}
    }
    .padding()
}