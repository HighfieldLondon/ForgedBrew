import Foundation

// A lightweight view-model row for NotesView: one cask that has a saved note.
// nonisolated so it can cross actor boundaries (DB read -> @MainActor view)
// under the project's SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor setting.
nonisolated struct NotedCask: Identifiable, Sendable, Hashable {
    let token: String
    let displayName: String
    let note: String

    var id: String { token }
}
