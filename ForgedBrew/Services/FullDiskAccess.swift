import Foundation

// Lightweight probe for macOS Full Disk Access (FDA). The TCC database
// directory at ~/Library/Application Support/com.apple.TCC is unreadable
// unless the app has been granted Full Disk Access in System Settings, so a
// successful directory listing is a reliable proxy for "FDA granted".
// Pure + nonisolated so it can be called from any context.
nonisolated enum FullDiskAccess {
    nonisolated static func isGranted() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.TCC")
        do {
            let _ = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            return true
        } catch {
            return false
        }
    }
}
