//
//  TagComponents.swift
//  ForgedBrew
//
//  Reusable tag UI, per our design outline for package tagging:
//   - TagChip:          a small colored capsule showing a tag's icon + name.
//   - TagSection:       the "Tags" block shown on a package detail page. Renders
//                       the package's current tag chips plus an "Add Tag" button
//                       that opens TagPickerPopover. Self-contained: it loads and
//                       mutates its own tag state via AppDataService, so it drops
//                       into both the cask DetailView and the FormulaDetailView
//                       with just a (token, type).
//   - TagPickerPopover: a checklist of all tags to toggle on/off for a package,
//                       with an inline "New Tag…" affordance.
//   - CreateOrEditTagSheet: create a new tag or edit an existing one
//                       (name + color + icon).
//
//  All of these live in the view layer (SwiftUI) and talk only to
//  AppDataService; the Tag model stays Foundation-only.
//

import SwiftUI

// MARK: - Tag chip

// A small colored capsule for a single tag. `removable` adds an (x) the user
// can tap to detach the tag inline.
struct TagChip: View {
    let tag: Tag
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tag.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(tag.name)
                .font(.caption)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove tag")
            }
        }
        .foregroundStyle(tag.color.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tag.color.color.opacity(0.15), in: Capsule())
        .overlay(Capsule().strokeBorder(tag.color.color.opacity(0.35), lineWidth: 0.5))
    }
}

// MARK: - Tag section (detail pages)

// The "Tags" block on a package detail page. Shows the package's current tags
// as removable chips and an "Add Tag" button that opens the picker. Owns its
// own state and refreshes it whenever the package or the global tag set changes.
struct TagSection: View {
    let token: String
    let type: PackageType

    @Environment(AppDataService.self) private var appData

    // Tags currently on this package.
    @State private var tags: [Tag] = []
    @State private var showingPicker = false
    // Bumped every time the picker opens so the popover reloads the full tag
    // list from the DB on each open. Without this the popover's `.task` only
    // runs once per reused view identity, so newly-created tags (e.g. a second
    // tag added after the picker was first shown) never appear in the list.
    @State private var pickerNonce = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Bordered "Add Tag" button (same style as the note buttons)
                // that opens the existing tag picker popover.
                Button("Add Tag", systemImage: "plus") {
                    // Force a fresh load of all tags on every open.
                    pickerNonce += 1
                    showingPicker = true
                }
                .buttonStyle(OutlinedButtonStyle())
                .controlSize(.small)
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    TagPickerPopover(token: token, type: type, reloadKey: pickerNonce, onChange: {
                        await reload()
                    })
                }
            }

            if tags.isEmpty {
                Text("No tags yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                // Each tag is a row with a one-click "Untag" button, matching the
                // Notes & Tags sidebar style — no click-into-picker needed to
                // remove a tag from this package.
                LazyVStack(spacing: 6) {
                    ForEach(tags) { tag in
                        HStack(spacing: 8) {
                            Image(systemName: tag.icon)
                                .foregroundStyle(tag.color.color)
                                .frame(width: 18)
                            Text(tag.name)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button("Untag", role: .destructive) {
                                Task {
                                    await appData.removeTag(tagId: tag.id, token: token, type: type)
                                    await reload()
                                }
                            }
                            .buttonStyle(OutlinedButtonStyle())
                            .controlSize(.small)
                            .help("Remove the \(tag.name) tag from this package")
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(tag.color.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .task(id: token) { await reload() }
        // Refresh the chips whenever the picker closes — belt-and-suspenders on
        // top of the popover's onChange callback, so toggles always reflect.
        .onChange(of: showingPicker) { _, isOpen in
            if !isOpen { Task { await reload() } }
        }
    }

    private func reload() async {
        tags = await appData.tags(forToken: token, type: type)
    }
}

// MARK: - Tag picker popover

// A single, self-contained popup for tagging a package: a checklist of all
// existing tags to reuse (tap to toggle on/off) plus an inline "create a new
// tag" row (name field + quick color swatches) right at the bottom. No separate
// sheet — selecting an existing tag and creating a new one both happen here.
// Calls `onChange` after every mutation so the host (TagSection) refreshes its
// chips.
struct TagPickerPopover: View {
    let token: String
    let type: PackageType
    // Changes on every open so `.task(id:)` re-reads the full tag list from the
    // DB each time the picker is shown (otherwise a reused view identity keeps a
    // stale snapshot and newly-created tags never appear).
    let reloadKey: Int
    let onChange: () async -> Void

    @Environment(AppDataService.self) private var appData

    @State private var allTags: [Tag] = []
    @State private var assignedIDs: Set<Int64> = []

    // Inline "new tag" state.
    @State private var newName: String = ""
    @State private var newColor: TagColor = .default
    @State private var newIcon: String = TagIcon.default
    @FocusState private var newNameFocused: Bool

    private var trimmedNewName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(allTags.isEmpty ? "New Tag" : "Tags")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if !allTags.isEmpty {
                // The list of existing tags to reuse. Each row toggles the tag
                // on/off for this package.
                //
                // IMPORTANT: a bare `ScrollView { … }.frame(maxHeight:)` inside
                // a content-sized popover collapses to ~0 height — SwiftUI
                // proposes no height to the popover, the ScrollView reports its
                // minimum (0), and the whole existing-tags list vanishes (the
                // "I only see the New Tag fields" bug). We instead give the list
                // a CONCRETE height that grows with the row count up to a cap, so
                // it's always visible and only scrolls when there are many tags.
                let rowHeight: CGFloat = 30
                let listHeight = min(CGFloat(allTags.count) * rowHeight, 220)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(allTags) { tag in
                            Button {
                                Task { await toggle(tag) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: assignedIDs.contains(tag.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(assignedIDs.contains(tag.id)
                                                         ? tag.color.color : Color.secondary)
                                    Image(systemName: tag.icon)
                                        .foregroundStyle(tag.color.color)
                                        .frame(width: 16)
                                    Text(tag.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 4)
                                .padding(.horizontal, 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: listHeight)

                Divider()
            }

            // Inline create-new-tag row: name field + a compact color picker +
            // an Add button. This is the whole "new tag" experience — no sheet.
            VStack(alignment: .leading, spacing: 8) {
                Text(allTags.isEmpty ? "Create your first tag" : "New tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    TextField("Tag name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .focused($newNameFocused)
                        .onSubmit { Task { await createNew() } }
                    Button {
                        Task { await createNew() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedNewName.isEmpty)
                    .help("Create this tag and add it to the package")
                }

                // Quick color swatches so a new tag isn't always the default
                // color.
                HStack(spacing: 6) {
                    ForEach(TagColor.allCases, id: \.self) { swatch in
                        Button {
                            newColor = swatch
                        } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().strokeBorder(
                                        Color.primary,
                                        lineWidth: newColor == swatch ? 2 : 0
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(swatch.displayName)
                    }
                }

                // Compact icon picker so a new tag can have its own glyph,
                // colored to match the selected swatch. Scrolls horizontally if
                // the choice list is long, keeping the popup narrow.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TagIcon.choices, id: \.self) { symbol in
                            Button {
                                newIcon = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 12))
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(newIcon == symbol ? newColor.color : Color.primary)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(newIcon == symbol
                                                  ? newColor.color.opacity(0.18)
                                                  : Color.secondary.opacity(0.08))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            .padding(12)
        }
        .frame(width: 240)
        .task(id: reloadKey) {
            await reload()
            // Put the cursor in the name field when there are no tags yet, so
            // the first-tag flow is one keystroke away.
            if allTags.isEmpty { newNameFocused = true }
        }
        // Belt-and-suspenders: also reload whenever the popover actually appears.
        // `.task(id:)` won't re-run if SwiftUI reuses this view's identity with
        // the same reloadKey, which could leave a stale (or empty) tag list. This
        // guarantees the full set of existing tags is always loaded on open.
        .onAppear { Task { await reload() } }
    }

    private func toggle(_ tag: Tag) async {
        if assignedIDs.contains(tag.id) {
            await appData.removeTag(tagId: tag.id, token: token, type: type)
        } else {
            await appData.addTag(tagId: tag.id, token: token, type: type)
        }
        await reload()
        await onChange()
    }

    // Create a brand-new tag from the inline fields and immediately attach it to
    // this package, then clear the field so another can be added.
    private func createNew() async {
        let trimmed = trimmedNewName
        guard !trimmed.isEmpty else { return }
        if let newTag = await appData.createTag(
            name: trimmed, color: newColor, icon: newIcon
        ) {
            await appData.addTag(tagId: newTag.id, token: token, type: type)
        }
        newName = ""
        newColor = .default
        newIcon = TagIcon.default
        await reload()
        await onChange()
        newNameFocused = true
    }

    private func reload() async {
        allTags = await appData.fetchTags()
        let assigned = await appData.tags(forToken: token, type: type)
        assignedIDs = Set(assigned.map { $0.id })
    }
}

// MARK: - Create / Edit tag sheet

// Create a new tag or edit an existing one. Pass `existing: nil` to create;
// pass a Tag to edit it in place. Calls `onSave` after a successful save so the
// caller can refresh.
struct CreateOrEditTagSheet: View {
    let existing: Tag?
    // When creating a tag from a package's detail page, pass that package here
    // so the new tag is immediately attached to it (and shows as a chip).
    let assignTo: TaggedItemRef?
    let onSave: () async -> Void

    @Environment(AppDataService.self) private var appData
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var color: TagColor
    @State private var icon: String

    init(existing: Tag?, assignTo: TaggedItemRef? = nil, onSave: @escaping () async -> Void) {
        self.existing = existing
        self.assignTo = assignTo
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _color = State(initialValue: existing?.color ?? .default)
        _icon = State(initialValue: existing?.icon ?? TagIcon.default)
    }

    private var isEditing: Bool { existing != nil }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Live preview tag built from the current field values.
    private var previewTag: Tag {
        Tag(id: existing?.id ?? -1,
            name: trimmedName.isEmpty ? "Tag name" : trimmedName,
            color: color, icon: icon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Tag" : "New Tag")
                .font(.title2.weight(.semibold))

            // Live preview chip.
            HStack {
                Spacer()
                TagChip(tag: previewTag)
                    .scaleEffect(1.2)
                Spacer()
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. Work, Games, Dev Tools", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                         count: 5), spacing: 8) {
                    ForEach(TagColor.allCases, id: \.self) { swatch in
                        Button {
                            color = swatch
                        } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle().strokeBorder(
                                        Color.primary,
                                        lineWidth: color == swatch ? 2.5 : 0
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(swatch.displayName)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                             count: 8), spacing: 8) {
                        ForEach(TagIcon.choices, id: \.self) { symbol in
                            Button {
                                icon = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 14))
                                    .frame(width: 30, height: 30)
                                    .foregroundStyle(icon == symbol ? color.color : Color.primary)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(icon == symbol
                                                  ? color.color.opacity(0.18)
                                                  : Color.secondary.opacity(0.08))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                }
                .frame(height: 110)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") {
                    Task {
                        if let existing {
                            await appData.updateTag(id: existing.id, name: trimmedName,
                                                    color: color, icon: icon)
                        } else {
                            // Create, then auto-attach to the originating package
                            // (if any) so it appears as a chip right away.
                            if let newTag = await appData.createTag(
                                name: trimmedName, color: color, icon: icon
                            ), let ref = assignTo {
                                await appData.addTag(tagId: newTag.id,
                                                     token: ref.token, type: ref.type)
                            }
                        }
                        await onSave()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380, height: 520)
    }
}

// MARK: - Simple wrapping flow layout

// A minimal wrapping HStack for chips. Uses the SwiftUI Layout protocol (no
// GeometryReader, per project rules) so chips flow onto multiple rows.
nonisolated struct TagFlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 6) {
        self.spacing = spacing
    }

    // Lay subviews into rows greedily within the proposed width, summing row
    // heights (+ inter-row spacing) for the total height.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let widthWithSpacing = currentRowWidth == 0 ? size.width : currentRowWidth + spacing + size.width
            if widthWithSpacing > maxWidth, currentRowWidth > 0 {
                totalHeight += currentRowHeight + spacing
                rows.append([size])
                currentRowWidth = size.width
                currentRowHeight = size.height
            } else {
                rows[rows.count - 1].append(size)
                currentRowWidth = widthWithSpacing
                currentRowHeight = max(currentRowHeight, size.height)
            }
        }
        totalHeight += currentRowHeight

        // Width: honor the proposed width when given; otherwise use the widest
        // row. Broken into explicit steps so the type-checker stays fast.
        let width: CGFloat
        if let proposed = proposal.width {
            width = proposed
        } else {
            var widest: CGFloat = 0
            for row in rows {
                var rowWidth: CGFloat = 0
                for size in row {
                    rowWidth += size.width
                }
                let gaps = CGFloat(max(0, row.count - 1)) * spacing
                rowWidth += gaps
                widest = max(widest, rowWidth)
            }
            width = widest
        }
        return CGSize(width: width, height: totalHeight)
    }

    // Place each subview left-to-right, wrapping to a new row (advancing y by the
    // tallest item in the completed row) once the next chip would overflow.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += currentRowHeight + spacing
                currentRowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}
