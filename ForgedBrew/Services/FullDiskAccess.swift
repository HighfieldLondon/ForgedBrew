import Foundation

// Lightweight probe for macOS Full Disk Access (FDA).
//
// The idea is unchanged since the first version: try to read something macOS
// only lets an FDA-granted app read, and take success as "granted". What
// changed is the something. Until macOS 26 this listed
// ~/Library/Application Support/com.apple.TCC — and treated ANY failure as
// "not granted". macOS 27 removed that per-user directory, so the listing
// failed with ENOENT before TCC was ever consulted, and every macOS 27 user
// saw "Full Disk Access not granted" no matter what System Settings said
// (reported 2026-09-17: toggling it off and on changed nothing, because the
// OS-side grant was already in place — TCC.db showed auth_value 2 with a
// matching code requirement — and the app simply never looked at it).
//
// So the probe now:
//   • walks a list of candidate paths, each present on the macOS versions we
//     support and each FDA-protected, starting with the system TCC database,
//     which has existed and been FDA-gated on every macOS since Mojave;
//   • distinguishes "denied" (EPERM/EACCES — TCC said no) from "absent"
//     (ENOENT — nothing to learn from this path, try the next);
//   • answers "not granted" ONLY when a path exists and access is refused.
//     If every candidate is absent it answers "granted": a false "granted"
//     just means the banner doesn't nag, and the tools still report their own
//     permission errors; a false "not granted" is the unfixable nag we just
//     shipped. The asymmetry is deliberate.
// Pure + nonisolated so it can be called from any context.
nonisolated enum FullDiskAccess {
    private enum Outcome { case granted, denied, absent }

    // Order matters: first conclusive answer wins.
    private static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            // System TCC database. Present on every macOS; world-readable at the
            // POSIX level but FDA-gated by TCC, so open() is the whole test.
            "/Library/Application Support/com.apple.TCC/TCC.db",
            // Per-user TCC directory — macOS ≤ 26 only (gone in 27).
            home + "/Library/Application Support/com.apple.TCC",
            // Further FDA-protected user data, present on most Macs.
            home + "/Library/Messages/chat.db",
            home + "/Library/Safari/Bookmarks.plist",
        ]
    }

    nonisolated static func isGranted() -> Bool {
        for path in candidates {
            switch probe(path) {
            case .granted: return true
            case .denied:  return false
            case .absent:  continue
            }
        }
        return true
    }

    // open(2) is enough: TCC's protection is enforced at open, and it returns
    // EPERM (not EACCES) for a TCC denial. Works for directories too.
    private static func probe(_ path: String) -> Outcome {
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        switch errno {
        case EPERM, EACCES: return .denied
        default:            return .absent   // ENOENT, ENOTDIR, …: not a verdict
        }
    }
}
