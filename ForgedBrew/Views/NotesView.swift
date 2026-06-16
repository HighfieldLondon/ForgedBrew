import SwiftUI

struct NoteEditor: View {
    let token: String
    let displayName: String
    @State private var text: String
    let onSave: (String) -> Void
    // Removes the note entirely (deletes the row from the list). Provided by
    // the host so it can refresh after deletion.
    var onRemove: (() -> Void)? = nil
    // Tapping the app name/header opens its detail page. Provided by the host.
    var onOpen: (() -> Void)? = nil

    init(token: String, displayName: String, initialText: String,
         onSave: @escaping (String) -> Void,
         onRemove: (() -> Void)? = nil,
         onOpen: (() -> Void)? = nil) {
        self.token = token
        self.displayName = displayName
        _text = State(initialValue: initialText)
        self.onSave = onSave
        self.onRemove = onRemove
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onOpen?()
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(token)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)

            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(minHeight: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
            HStack(spacing: 8) {
                Spacer()
                if onRemove != nil {
                    Button("Remove", role: .destructive) {
                        onRemove?()
                    }
                    .buttonStyle(OutlinedButtonStyle())
                    .controlSize(.small)
                    .help("Delete this note")
                }
                Button("Save") {
                    onSave(text)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}

// The two panes of the combined view: saved notes, and user-defined tags.
private enum NotesTagsTab: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case tags = "Tags"
    var id: String { rawValue }
}

struct NotesView: View {
    // Opens the detail page for a tapped tagged package. Provided by ForgedBrewApp.
    var onPackageTapped: ((String, PackageType) -> Void)? = nil

    @Environment(AppDataService.self) var appData
    @State private var noted: [NotedCask] = []
    @State private var isLoading = false
    @State private var tab: NotesTagsTab = .notes

    private func reload() async {
        isLoading = true
        noted = await appData.fetchNotedCasks()
        isLoading = false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageTitleLabel(title: "Notes & Tags")

                Picker("", selection: $tab) {
                    ForEach(NotesTagsTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .labelsHidden()

                switch tab {
                case .notes: notesPane
                case .tags:  TagsPane(onPackageTapped: onPackageTapped)
                }
            }
            .padding(20)
        }
        .task {
            await reload()
        }
    }

    // MARK: Notes pane

    @ViewBuilder
    private var notesPane: some View {
        notesPaneContent
    }

    @ViewBuilder
    private var notesPaneContent: some View {
        Text("\(noted.count) apps with notes")
            .font(.callout)
            .foregroundStyle(.secondary)

        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if noted.isEmpty {
            VStack(spacing: 20) {
                Image(systemName: "note.text")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("No notes yet")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Add a note from an app's detail page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 80)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(noted) { item in
                    NoteEditor(
                        token: item.token,
                        displayName: item.displayName,
                        initialText: item.note,
                        onSave: { newText in
                            Task {
                                await appData.saveNote(token: item.token, note: newText)
                                await reload()
                            }
                        },
                        onRemove: {
                            Task {
                                // Saving an empty note deletes the row.
                                await appData.saveNote(token: item.token, note: "")
                                await reload()
                            }
                        },
                        onOpen: {
                            onPackageTapped?(item.token, .cask)
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Tags pane

// Lists all user-defined tags with their item counts. Selecting a tag filters
// to the packages carrying it. Supports creating, editing, and deleting tags.
private struct TagsPane: View {
    var onPackageTapped: ((String, PackageType) -> Void)? = nil

    @Environment(AppDataService.self) private var appData

    @State private var tags: [Tag] = []
    @State private var isLoading = false
    // Tagged packages for every tag, keyed by tag id, so each tag's apps are
    // always shown inline (no click-to-expand).
    @State private var taggedByTag: [Int64: [TaggedPackage]] = [:]
    @State private var showingCreate = false
    @State private var editing: Tag? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(tags.count) tag\(tags.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingCreate = true
                } label: {
                    Label("New Tag", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if tags.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "tag")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("No tags yet")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Create a tag, then add it to apps and formulae from their detail pages.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                // Each tag is always shown with its tagged apps listed inline.
                LazyVStack(spacing: 14) {
                    ForEach(tags) { tag in
                        tagCard(tag)
                    }
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showingCreate) {
            CreateOrEditTagSheet(existing: nil) { await reload() }
        }
        .sheet(item: $editing) { tag in
            CreateOrEditTagSheet(existing: tag) { await reload() }
        }
    }

    // A tag shown as a card: header (icon, name, count, Edit, Delete) followed
    // by its tagged apps, each with a Remove button. Mirrors the Notes pane:
    // visible, labeled bordered buttons instead of a hidden hover menu.
    @ViewBuilder
    private func tagCard(_ tag: Tag) -> some View {
        let items = taggedByTag[tag.id] ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: tag.icon)
                    .foregroundStyle(tag.color.color)
                    .frame(width: 20)
                Text(tag.name)
                    .font(.system(size: 15, weight: .semibold))
                Text("\(tag.itemCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Spacer()
                Button("Edit") { editing = tag }
                    .buttonStyle(OutlinedButtonStyle())
                    .controlSize(.small)
                    .help("Rename or restyle this tag")
                Button("Delete", role: .destructive) {
                    Task {
                        await appData.deleteTag(id: tag.id)
                        await reload()
                    }
                }
                .buttonStyle(OutlinedButtonStyle())
                .controlSize(.small)
                .help("Delete this tag from all apps")
            }

            if items.isEmpty {
                Text("Nothing tagged yet. Open an app or formula and add this tag from its detail page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(items) { pkg in
                        taggedRow(tag: tag, pkg: pkg)
                    }
                }
            }
        }
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    // One tagged package under a tag. Tapping the row opens its detail page;
    // the Remove button strips just this tag from this package.
    @ViewBuilder
    private func taggedRow(tag: Tag, pkg: TaggedPackage) -> some View {
        HStack(spacing: 10) {
            Button {
                onPackageTapped?(pkg.token, pkg.type)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: pkg.type == .cask ? "app.fill" : "terminal.fill")
                        .foregroundStyle(pkg.type == .cask ? Color.blue : Color.green)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pkg.displayName)
                            .font(.system(size: 13, weight: .medium))
                        if let desc = pkg.desc, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(pkg.type == .cask ? "App" : "Formula")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button("Untag", role: .destructive) {
                Task {
                    await appData.removeTag(tagId: tag.id, token: pkg.token, type: pkg.type)
                    await reload()
                }
            }
            .buttonStyle(OutlinedButtonStyle())
            .controlSize(.small)
            .help("Remove the \(tag.name) tag from \(pkg.displayName)")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func reload() async {
        isLoading = true
        tags = await appData.fetchTags()
        // Load every tag's package list so all tags render expanded.
        var map: [Int64: [TaggedPackage]] = [:]
        for tag in tags {
            map[tag.id] = await appData.taggedPackages(tagId: tag.id)
        }
        taggedByTag = map
        isLoading = false
    }
}
