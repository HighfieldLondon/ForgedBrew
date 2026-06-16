import SwiftUI
import AppKit

struct BrewfileView: View {
    @Environment(AppDataService.self) var appData
    @State private var previewText = ""
    // Raw stream lines from the import. Kept internally to DERIVE the friendly
    // batch status (total / current package / phase / done) — no longer rendered
    // as a pseudo-terminal. The UI shows our own status text + green progress
    // bar, matching Update All and the per-app install surfaces.
    @State private var importLog: [String] = []
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>? = nil

    // When presented in a sheet (e.g. from Maintenance), the host passes a
    // dismiss closure so the header can show a Done button. nil when shown as a
    // full page, where no Done affordance is needed.
    var onDone: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        PageTitleLabel(title: "Brewfile")
                        Text("Export your setup or restore from a Brewfile")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let onDone {
                        Button("Done") { onDone() }
                            .keyboardShortcut(.defaultAction)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export Brewfile")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Save all installed packages to a file")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Export…") {
                            exportTapped()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if !previewText.isEmpty {
                        ScrollView {
                            Text(previewText)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 160)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import Brewfile")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Install everything from a Brewfile")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(isImporting ? "Importing…" : "Import…") {
                            importTapped()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isImporting)
                    }

                    if !importLog.isEmpty {
                        importStatusPanel
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
            }
            .padding(20)
        }
        .task {
            previewText = appData.brewfilePreview()
        }
    }

    // MARK: - Import status (derived from the stream)

    // Total packages the import found, parsed from the opening
    // "Found N package(s) to install." line. nil until that line arrives.
    private var importTotal: Int? {
        for line in importLog {
            if line.hasPrefix("Found "),
               let n = Int(line.dropFirst(6).prefix(while: { $0.isNumber })) {
                return n
            }
        }
        return nil
    }

    // The package currently being installed and its 1-based index, parsed from
    // the "==> Installing cask/formula <name>" markers the importer emits before
    // each package.
    private var currentPackage: (index: Int, name: String)? {
        var idx = 0
        var name: String? = nil
        for line in importLog {
            if let r = line.range(of: "==> Installing ") {
                idx += 1
                // Drop the "cask " / "formula " kind word, keep the package name.
                let rest = line[r.upperBound...]
                name = rest.split(separator: " ", maxSplits: 1).last.map(String.init) ?? String(rest)
            }
        }
        guard let name else { return nil }
        return (idx, name)
    }

    // Number of packages fully started (== current index). Used for the counter.
    private var startedCount: Int { currentPackage?.index ?? 0 }

    // A failure/empty message from the importer, if any (e.g. unreadable file,
    // empty Brewfile, or a brew "Error: …" line).
    private var importFailed: String? {
        if let err = importLog.last(where: {
            $0.localizedCaseInsensitiveContains("error:") ||
            $0.hasPrefix("Error reading Brewfile") ||
            $0.hasPrefix("No formulae or casks")
        }) {
            return err
        }
        return nil
    }

    // True once the importer reached the final deep cache-clean step (the
    // "==> Cleaning up cache" marker we emit after all packages install).
    private var isCleaningCache: Bool {
        importLog.contains("==> Cleaning up cache")
    }

    // Live phase for the package currently installing, from its latest brew
    // ==> marker. During the closing cache clean we show "Cleaning up…" since
    // brew's cleanup output has no ==> phase marker of its own. Falls back to
    // "Preparing…" until brew emits its first marker.
    private var phaseLabel: String {
        if isCleaningCache { return "Cleaning up…" }
        for line in importLog.reversed() {
            if let phase = InstallProgress.phase(forLine: line) { return phase.statusLabel }
        }
        return "Preparing…"
    }

    private var phaseSymbol: String {
        if isCleaningCache { return "sparkles" }
        for line in importLog.reversed() {
            if let phase = InstallProgress.phase(forLine: line) { return phase.statusSymbol }
        }
        return "hourglass"
    }

    // Friendly batch-import status: our own headline, phase line, a bright-green
    // flowing progress bar, and an "X of Y" package counter — no raw terminal
    // output. Mirrors how Update All reports progress.
    private var importStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Headline reflects overall state.
            HStack(spacing: 8) {
                if isImporting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else if importFailed != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                // Package counter (X of Y), shown once we know the total.
                if let total = importTotal, total > 0 {
                    Text("\(min(startedCount, total)) of \(total)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Live phase line for the package currently installing.
            if isImporting {
                HStack(spacing: 6) {
                    Image(systemName: phaseSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(isCleaningCache
                         ? phaseLabel
                         : (currentPackage.map { "\(phaseLabel.replacingOccurrences(of: "…", with: "")) \($0.name)…" } ?? phaseLabel))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                GreenDashProgressBar()
                    .frame(height: 4)
            }

            // Red failure banner with the importer's message.
            if let importFailed, !importFailed.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                    Text(importFailed)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }

    // Overall headline for the import panel.
    private var headline: String {
        if isImporting {
            if let total = importTotal { return "Importing \(total) package\(total == 1 ? "" : "s")" }
            return "Importing from Brewfile"
        }
        if importFailed != nil { return "Import failed" }
        if let total = importTotal, total > 0 {
            return "Imported \(total) package\(total == 1 ? "" : "s")"
        }
        return "Import finished"
    }

    private func exportTapped() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Brewfile"
        if panel.runModal() == .OK, let url = panel.url {
            try? appData.exportBrewfile(to: url)
        }
    }

    private func importTapped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            isImporting = true
            importLog = []
            importTask?.cancel()
            importTask = Task {
                let stream = appData.importBrewfile(from: url)
                for await line in stream {
                    importLog.append(line)
                }
                isImporting = false
            }
        }
    }
}
