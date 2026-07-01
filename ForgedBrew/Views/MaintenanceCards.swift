//
//  MaintenanceCards.swift
//  ForgedBrew
//
//  Reusable card views for the Maintenance screen, split out of MaintenanceView:
//  HealthRing (the circular 0–100 health gauge) and ActionCard (a one-tap card
//  whose button streams brew CLI output and distils it to one status line). Pure
//  code motion — behaviour unchanged.
//

import SwiftUI
import AppKit

/// A circular progress gauge for the overall health score (0–100). Colour is
/// derived from the score (green > 80, yellow > 50, red otherwise) and the trim
/// animates as the score changes.
struct HealthRing: View {
    let score: Int  // 0–100

    private var color: Color {
        if score > 80 { return .green }
        else if score > 50 { return .yellow }
        else { return .red }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 1.0), value: score)
            VStack(spacing: 2) {
                Text("\(score)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("Health")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 90, height: 90)
    }
}

/// A reusable one-tap "action" card (icon + title + description + a single
/// button) whose action streams brew CLI output. The raw output is never shown:
/// while it runs the card shows a spinner, and on completion `resultSummary`
/// distils the collected lines into one friendly status line. Used for the
/// Homebrew Cache cleanup card; other cards on this screen open sheets instead.
struct ActionCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    /// Builds and returns the stream of CLI output lines for this card's action.
    let onRun: () async -> AsyncStream<String>
    // Optional closure that turns the collected command output into a single
    // friendly status line (e.g. "Ready to brew" for Doctor). When nil, a
    // generic "All set" message is shown. We never display raw terminal output
    // — these cards are meant to feel like one-tap, consumer-grade actions.
    var resultSummary: (([String]) -> String)? = nil

    // Label for the action button. Defaults to "Run"; the cleanup card uses
    // "Clean Up".
    var primaryTitle: String = "Run"

    // Optional explanatory footnote rendered under the card header (e.g. the
    // Homebrew Cache card uses this to explain that ForgedBrew already cleans the
    // cache automatically on install/update).
    var note: String? = nil

    @State private var isRunning = false
    @State private var isDone = false
    @State private var summary: String = ""
    @State private var log: [String] = []
    @State private var task: Task<Void, Never>? = nil
    @State private var needsPermission = false

    // Detects the macOS TCC permission block that occurs when the app process
    // lacks Full Disk Access and brew tries to write into ~/Library/Caches.
    private func isPermissionError(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("operation not permitted")
            || (l.contains("permission denied") && l.contains("cache"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .foregroundStyle(iconColor)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    run(onRun)
                } label: {
                    Text(isRunning ? "Running…" : primaryTitle)
                }
                .buttonStyle(PillActionButtonStyle())
                // Re-enabled once the run finishes so the user can run it again.
                .disabled(isRunning)
            }
            .padding(14)

            // Optional explanatory footnote (e.g. "cleaned automatically on
            // install/update"). Sits just under the header, above any result row.
            if let note {
                Divider()
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            // Friendly result row — a single status line (no raw terminal output).
            // Shows a spinner while running, then a green check + summary once done.
            if isRunning || (isDone && !summary.isEmpty) {
                Divider()
                HStack(spacing: 8) {
                    if isRunning {
                        ProgressView().scaleEffect(0.6)
                        Text("Working…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                        Text(summary)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            // macOS permission guidance (Full Disk Access)
            if needsPermission {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Permission needed")
                                .font(.system(size: 12, weight: .semibold))
                            Text("macOS blocked ForgedBrew from modifying Homebrew's cache. Grant ForgedBrew Full Disk Access, then try again.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // Resets the card to its running state, then drains the action's stream on a
    // background Task: each line is appended to `log` on the main actor (watching
    // for the TCC permission block as it goes), and once the stream ends the
    // collected log is reduced to a single `summary` line. Any previous Task is
    // cancelled first so re-running mid-flight can't leave two streams racing.
    private func run(_ action: @escaping () async -> AsyncStream<String>) {
        isRunning = true
        isDone = false
        needsPermission = false
        summary = ""
        log = []
        task?.cancel()
        task = Task {
            let stream = await action()
            for await line in stream {
                let permissionHit = isPermissionError(line)
                await MainActor.run {
                    log.append(line)
                    if permissionHit { needsPermission = true }
                }
            }
            await MainActor.run {
                // Derive the friendly one-line status from the collected output.
                // The raw output is never shown to the user.
                summary = resultSummary?(log) ?? "All set"
                isRunning = false
                isDone = true
            }
        }
    }
}
