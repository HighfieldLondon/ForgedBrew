import SwiftUI

// A pure-SwiftUI indeterminate spinner used app-wide in place of the system
// circular ProgressView.
//
// Why this exists: on macOS the system circular ProgressView is backed by an
// AppKit host view (AppKitProgressView). Inside flexible SwiftUI containers
// (ZStacks filling infinite frames, overlays, scaled views) that host emits a
// stream of benign-but-noisy console warnings:
//   • "_NSDetectedLayoutRecursion … -layoutSubtreeIfNeeded …"
//   • "AppKitProgressView … maximum length (32.14…) doesn't satisfy min <= max"
// Drawing the spinner ourselves with SwiftUI shapes removes the AppKit host
// entirely, so the warnings disappear and sizing is deterministic.

/// App-wide replacement for the system circular ProgressView. Apply via
/// `.progressViewStyle(.forgedbrew)`; renders an indeterminate spinning arc or,
/// when a fraction is reported, a determinate fill ring.
struct ForgedBrewSpinnerStyle: ProgressViewStyle {
    // Diameter of the spinner in points.
    var size: CGFloat = 20
    // Stroke thickness of the arc.
    var lineWidth: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        // Indeterminate (no fraction) → animated arc. Determinate → a ring that
        // fills to the reported fraction (rare in this app, but handled).
        if let fraction = configuration.fractionCompleted {
            DeterminateRing(fraction: fraction, size: size, lineWidth: lineWidth)
        } else {
            SpinningArc(size: size, lineWidth: lineWidth)
        }
    }
}

// The indeterminate variant: a 270° arc that rotates continuously.
private struct SpinningArc: View {
    let size: CGFloat
    let lineWidth: CGFloat
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(
                Color.secondary.opacity(0.7),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: spinning
            )
            // Fixed frame so the parent never proposes an ambiguous size to a
            // platform view (the original source of the min<=max warning).
            .frame(width: size, height: size)
            .onAppear { spinning = true }
    }
}

// The determinate variant: a static track plus a fill arc.
private struct DeterminateRing: View {
    let fraction: Double
    let size: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, fraction))))
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

extension ProgressViewStyle where Self == ForgedBrewSpinnerStyle {
    // Convenience so call sites can write `.progressViewStyle(.forgedbrew)`.
    static var forgedbrew: ForgedBrewSpinnerStyle { ForgedBrewSpinnerStyle() }
    // A slightly larger variant for full-screen loading states.
    static var forgedbrewLarge: ForgedBrewSpinnerStyle {
        ForgedBrewSpinnerStyle(size: 28, lineWidth: 3)
    }
}
