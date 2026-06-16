import SwiftUI

// A bright-green, indeterminate progress bar made of a row of short dashes that
// flow from left to right while an operation is in flight. Homebrew doesn't
// report a reliable percentage across its phases (download → verify → install →
// cleanup), so this is a continuous "work is happening" indicator that runs the
// whole time a package is updating, sitting under the per-app status text.
//
// The motion is a travelling brightness wave: every dash is drawn, and a moving
// highlight sweeps across them left→right on a loop, so it reads as motion in a
// single direction (not a back-and-forth pulse).
//
// Driven by TimelineView (a frame-clock) rather than withAnimation(.repeatForever).
// The latter is unreliable for continuous motion inside List/ForEach rows — it
// frequently fails to start or gets cancelled on row updates. TimelineView ticks
// independently of view state, so the bar always animates while it's on screen.
struct GreenDashProgressBar: View {
    // Tint for the flowing dashes. Defaults to the punchy install green, but
    // callers pass red for uninstall operations so the bar's color matches the
    // operation kind (green = install/update, red = uninstall).
    var tint: Color = Color(red: 0.16, green: 0.86, blue: 0.30)

    // Number of dashes. The ask was "15-20"; 18 reads well at the row width.
    private let dashCount = 18

    // Half-width of the bright band, in 0...1 bar-position units. The band is
    // roughly a third of the bar wide.
    private let bandHalfWidth: CGFloat = 0.18

    // Seconds for one full sweep of the crest across the bar.
    private let period: Double = 1.3

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // Crest position sweeps from just off the left edge to just off the
            // right edge, then restarts. The off-edge margins give a brief
            // all-dim gap before the band re-enters from the left, so it's never
            // lit on both sides at once.
            let span = 1 + 2 * Double(bandHalfWidth)
            let phase = CGFloat(-Double(bandHalfWidth) + (t.truncatingRemainder(dividingBy: period) / period) * span)

            HStack(spacing: 4) {
                ForEach(0..<dashCount, id: \.self) { i in
                    Capsule()
                        .fill(tint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 4)
                        .opacity(opacity(for: i, phase: phase))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("In progress")
    }

    // Opacity for dash `i`: a smooth bump centred on the wave crest. The crest
    // sweeps in a single pass from off-screen left to off-screen right, so the
    // bright band is only ever in one place at a time.
    private func opacity(for index: Int, phase: CGFloat) -> Double {
        let pos = CGFloat(index) / CGFloat(dashCount - 1)   // 0...1 along the bar
        let dist = abs(pos - phase)
        if dist >= bandHalfWidth { return 0.18 }
        let band = 1 - (dist / bandHalfWidth)               // 1 at crest → 0 at edge
        return 0.18 + Double(band) * 0.82                   // 0.18 (dim) → 1.0 (bright)
    }
}

#Preview {
    GreenDashProgressBar()
        .frame(width: 240)
        .padding()
}