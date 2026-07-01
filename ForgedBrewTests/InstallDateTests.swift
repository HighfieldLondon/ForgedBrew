import Foundation
import Testing
@testable import ForgedBrew

// bundleInstallDate reads a bundle's creation/modification date but must reject
// the classic-Mac "zero" epoch (~1904) that a Sparkle in-place self-update
// leaves behind — otherwise the app showed "Installed Dec 31, 1903" and sorted
// wrong. These write real temp files with controlled dates to prove the guard.
struct InstallDateTests {

    private func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("forgedbrew-installdate-\(UUID().uuidString)")
        try Data().write(to: url)
        return url
    }

    @Test func nonexistentPathReturnsNil() {
        let path = "/no/such/forgedbrew/\(UUID().uuidString)"
        #expect(AppUpdateService.bundleInstallDate(atPath: path) == nil)
    }

    @Test func pre2001DatesAreRejected() throws {
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        // Both creation and modification set to ~1990 — everything the function
        // can read is implausible, so it must return nil rather than a 1990 date.
        let ancient = Date(timeIntervalSince1970: 631_152_000) // 1990-01-01
        try FileManager.default.setAttributes(
            [.creationDate: ancient, .modificationDate: ancient],
            ofItemAtPath: file.path)

        #expect(AppUpdateService.bundleInstallDate(atPath: file.path) == nil)
    }

    @Test func plausibleModificationDateFallsThrough() throws {
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        // A pre-2001 creation date but a real modification date → the mod date
        // is returned (the "just updated" proxy), never the bogus creation date.
        let ancient = Date(timeIntervalSince1970: 631_152_000)  // 1990
        let recent = Date(timeIntervalSinceReferenceDate: 600_000_000) // ~2020
        try FileManager.default.setAttributes(
            [.creationDate: ancient, .modificationDate: recent],
            ofItemAtPath: file.path)

        let result = AppUpdateService.bundleInstallDate(atPath: file.path)
        #expect(result != nil)
        // Whatever comes back must be plausible (>= the 2001 reference epoch).
        if let result {
            #expect(result >= Date(timeIntervalSinceReferenceDate: 0))
        }
    }
}
