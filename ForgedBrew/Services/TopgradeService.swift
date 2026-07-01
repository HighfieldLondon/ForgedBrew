import Foundation

// MARK: - TopgradeService
//
// DORMANT (2026-07): this service is currently UNWIRED. In-place app updating was
// removed from the Mac Store/Other Apps screens (now awareness-only) because many
// apps failed silently on update — App Store binding and false "update available"
// run routines made topgrade/MAS updates unreliable. The file is retained, not
// deleted, to revisit later for a better topgrade integration. Its only remaining
// caller is the AppDataService "App updates via topgrade" block (itself dormant)
// and a status read in Settings.
//
// Drives the `topgrade` CLI to perform IN-PLACE updates of non-Homebrew apps
// (Mac App Store, Sparkle-based, Homebrew casks, Microsoft Office) — the apps
// surfaced on the "Mac & Other Apps" screen that ForgedBrew previously could only
// send the user to a website/App Store page to update manually.
//
// Design mirrors BrewCLIService.run(): spawn the process, stream whole lines
// from a merged stdout+stderr pipe (draining continuously so a full pipe can
// never deadlock the child), strip ANSI, and finish the stream exactly once at
// EOF. Reuses the top-level OneShot / LineBuffer helpers from BrewCLIService.
//
// Auth model: topgrade calls plain `sudo` for steps that need root. We point
// SUDO_ASKPASS at a one-shot helper script that echoes the session password
// (same mechanism BrewCLIService uses), so privileged updates complete without
// an interactive terminal prompt. The password file is 0600, written to the
// temp dir, and deleted the instant the run ends. mas (App Store) updates need
// no root at all; Office uses its own privileged updater.
@MainActor
final class TopgradeService {
    static let shared = TopgradeService()
    private init() {}

    // Absolute path to the topgrade binary. Apple-Silicon Homebrew first, then
    // Intel. nil when topgrade isn't installed (callers degrade gracefully).
    nonisolated static var topgradePath: String? {
        let candidates = ["/opt/homebrew/bin/topgrade", "/usr/local/bin/topgrade"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    nonisolated static var isInstalled: Bool { topgradePath != nil }

    // The topgrade step name for each AppUpdate source. GitHub-release apps have
    // no dedicated topgrade step, so they return nil (the UI keeps the "Website"
    // path for those).
    nonisolated static func step(for source: AppUpdateSource) -> String? {
        switch source {
        case .appStore:     return "mas"
        case .sparkle:      return "sparkle"
        // Homebrew casks for non-Homebrew installs can't be updated in place
        // by topgrade (the brew_cask step fails when the app wasn't adopted),
        // so we expose no in-place step. The UI offers Adopt + Open App +
        // Website instead. nil here removes the dead Update button everywhere
        // (row button, select-all, Update All) since all gate on this.
        case .homebrewCask: return nil
        case .github:       return nil
        }
    }

    // True when this source can be updated in place by topgrade.
    nonisolated static func canUpdateInPlace(_ source: AppUpdateSource) -> Bool {
        step(for: source) != nil
    }

    // MARK: - Run

    // Runs topgrade for the given steps, streaming merged output line-by-line.
    // `steps` are topgrade step identifiers (e.g. "mas", "sparkle", "brew_cask",
    // "microsoft_office"). When `sudoPassword` is non-nil we wire up SUDO_ASKPASS
    // so privileged steps authenticate non-interactively.
    func run(steps: [String], sudoPassword: String?) -> AsyncStream<String> {
        guard let path = TopgradeService.topgradePath else {
            return errorStream("Error: topgrade is not installed. Install it with `brew install topgrade`.")
        }
        guard !steps.isEmpty else {
            return errorStream("Error: no update steps were requested.")
        }

        let askpass = sudoPassword.flatMap { TopgradeService.writeAskpassAssets(password: $0) }
        let configPath = TopgradeService.writeManagedConfig()

        return AsyncStream<String> { (continuation: AsyncStream<String>.Continuation) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)

            // --config <managed>  : never touch the user's real ~/.config/topgrade.toml
            // --no-ask-retry      : never block waiting on a "retry? [y/n]" prompt
            // -y / --yes          : auto-confirm package-manager prompts for our steps
            // --only <steps...>   : run ONLY the requested steps
            var args: [String] = []
            if let configPath { args += ["--config", configPath] }
            args += ["--no-ask-retry", "--yes"]
            args += ["--only"] + steps
            process.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            // Keep Homebrew quiet/deterministic for the cask step.
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            // Non-interactive sudo: topgrade calls `sudo`, which uses the askpass
            // helper when SUDO_ASKPASS is set and sudo is invoked with -A. brew's
            // own sudo path is -A; for topgrade's direct `sudo` calls we ALSO set
            // SUDO_ASKPASS so any -A-capable invocation can read the password.
            // The reliable channel is the password file the helper cats.
            if let password = sudoPassword, let askpass {
                env["SUDO_ASKPASS"] = askpass.scriptPath
                env["FORGEDBREW_ASKPASS_PASSWORD"] = password
            }
            process.environment = env

            // Delete the one-shot password file as soon as the run ends.
            let pwFilePath = askpass?.passwordFilePath
            let wipePasswordFile: () -> Void = {
                if let pwFilePath { try? FileManager.default.removeItem(atPath: pwFilePath) }
                if let configPath { try? FileManager.default.removeItem(atPath: configPath) }
            }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let finishOnce = OneShot()
            let finishStream: @Sendable () -> Void = {
                guard finishOnce.fire() else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                wipePasswordFile()
                continuation.finish()
            }

            // Reassemble output into whole lines. topgrade emits a lot of ANSI
            // (cursor moves, \r line rewrites, color); we strip it and only emit
            // non-empty trimmed lines. Drain continuously so the child never
            // blocks on a full pipe.
            let lineBuffer = LineBuffer()
            let emit: @Sendable (String) -> Void = { chunk in
                let stripped = TopgradeService.stripANSI(chunk)
                if !stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                    continuation.yield(stripped)
                }
            }

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    if let tail = lineBuffer.flush() { emit(tail) }
                    finishStream()
                    return
                }
                for line in lineBuffer.appendAndExtractLines(data) { emit(line) }
            }

            process.terminationHandler = { _ in
                // Safety net: EOF normally finishes first, but make sure we never
                // leak the readability handler or the password file.
                finishStream()
            }

            do {
                try process.run()
            } catch {
                continuation.yield("Error: failed to launch topgrade — \(error.localizedDescription)")
                finishStream()
            }
        }
    }

    // MARK: - Helpers

    private func errorStream(_ message: String) -> AsyncStream<String> {
        AsyncStream { (continuation: AsyncStream<String>.Continuation) in
            continuation.yield(message)
            continuation.finish()
        }
    }

    // Writes a ForgedBrew-managed topgrade config to a temp file and returns its
    // path. We never edit the user's real config. Disables topgrade self-update
    // (we don't want a ForgedBrew click upgrading topgrade itself) and makes runs
    // non-interactive. Returns nil if the write fails (run proceeds config-less).
    nonisolated static func writeManagedConfig() -> String? {
        let dir = NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("forgedbrew-topgrade.toml")
        let body = """
        [misc]
        assume_yes = true
        no_retry = true
        disable = ["self_update"]
        skip_notify = true
        cleanup = false
        """
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }

    // One-shot askpass assets, identical in shape to BrewCLIService's: a 0600
    // password file plus a 0700 helper script that cats it. Returns nil on any
    // filesystem failure (the caller then runs without SUDO_ASKPASS).
    nonisolated struct AskpassAssets { let scriptPath: String; let passwordFilePath: String }

    nonisolated static func writeAskpassAssets(password: String) -> AskpassAssets? {
        let dir = NSTemporaryDirectory()
        // Per-operation random suffix so two concurrent topgrade runs can't share
        // (and delete out from under each other) the same password file, and so
        // the path isn't predictable/pre-creatable by another local user.
        let nonce = UUID().uuidString
        let scriptURL = URL(fileURLWithPath: dir).appendingPathComponent("forgedbrew-tg-askpass-\(nonce).sh")
        let pwURL = URL(fileURLWithPath: dir).appendingPathComponent("forgedbrew-tg-askpass-pw-\(nonce)")
        let pwBytes = Data((password + "\n").utf8)
        let body = """
        #!/bin/sh
        if [ -f "\(pwURL.path)" ]; then
          cat "\(pwURL.path)"
        elif [ -n "$FORGEDBREW_ASKPASS_PASSWORD" ]; then
          printf '%s\\n' "$FORGEDBREW_ASKPASS_PASSWORD"
        fi
        """
        do {
            try pwBytes.write(to: pwURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pwURL.path)
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return AskpassAssets(scriptPath: scriptURL.path, passwordFilePath: pwURL.path)
        } catch {
            return nil
        }
    }

    // Strips ANSI escape sequences (CSI color/cursor codes) and bare carriage
    // returns that topgrade uses to rewrite a status line in place. Keeping the
    // text after the last \r in a chunk mirrors how a terminal would render it.
    nonisolated static func stripANSI(_ string: String) -> String {
        var s = string
        // Remove CSI sequences: ESC [ ... <final byte 0x40–0x7E>
        if let regex = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]") {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        // Collapse in-place line rewrites: keep only what's after the last \r in
        // each \n-delimited segment.
        let lines = s.components(separatedBy: "\n").map { segment -> String in
            if let lastCR = segment.range(of: "\r", options: .backwards) {
                return String(segment[lastCR.upperBound...])
            }
            return segment
        }
        return lines.joined(separator: "\n")
    }
}
