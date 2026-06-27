import SwiftUI
import AppKit

// MARK: - User Manual
//
// A complete, in-app, scrollable user manual for ForgedBrew. Rebuilt as a true
// two-pane reference: a Table of Contents + live filter on the left, and rich,
// top-to-bottom documentation on the right. Every part of the app is covered in
// detail, in the same order it appears in the sidebar, and each section carries
// a hand-drawn DARK-MODE wireframe of that screen with numbered annotation
// circles pointing at exactly what to click.
//
// Everything is pure SwiftUI (no bitmap screenshots needed): the wireframes are
// drawn with shapes and SF Symbols so they stay crisp at any size and always
// match dark mode. Written for someone who has never opened ForgedBrew before.
//
// The window is declared as a `Window` scene in ForgedBrewApp (see
// UserManualWindowID) and opened with `openWindow(id:)`.

// Stable identifier shared by the Window scene and the openWindow(id:) call.
let UserManualWindowID = "forgedbrew-user-manual"

// MARK: - Manual entry point

struct UserManualView: View {
    @Environment(\.dismiss) private var dismiss

    // Live filter text for the Table of Contents / content.
    @State private var query = ""
    // The section the user asked to jump to (drives the ScrollViewReader).
    @State private var scrollTarget: String? = nil

    // Sections that match the current filter. Matching looks at the title,
    // every paragraph, and every bullet, so searching e.g. "quarantine" or
    // "park" surfaces the right place even if it isn't in a heading.
    private var visibleSections: [ManualSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return ManualSection.all }
        return ManualSection.all.filter { $0.matches(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            tableOfContents
            Divider()
            content
        }
        .frame(minWidth: 880, idealWidth: 1040, minHeight: 600, idealHeight: 800)
        .background(.background)
    }

    // MARK: Left rail - Table of Contents + search

    private var tableOfContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("ForgedBrewLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ForgedBrew")
                        .font(.system(size: 14, weight: .bold))
                    Text("User Manual")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // In-manual search.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search the manual", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            // Clickable contents list. Tapping sets scrollTarget, which the
            // content pane's ScrollViewReader observes to scroll into view.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONTENTS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(visibleSections) { section in
                        Button {
                            // Nudge to nil first so tapping the same row twice
                            // still triggers onChange in the content pane.
                            scrollTarget = nil
                            DispatchQueue.main.async { scrollTarget = section.id }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: section.systemImage)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tint)
                                    .frame(width: 18)
                                Text(section.title)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if visibleSections.isEmpty {
                        Text("No matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(width: 248)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: Right pane - content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    if query.isEmpty {
                        intro
                    }

                    ForEach(visibleSections) { section in
                        ManualSectionView(section: section)
                            .id(section.id)
                    }

                    if visibleSections.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No matches for \u{201C}\(query)\u{201D}")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Try a different word \u{2014} for example \u{201C}update\u{201D}, \u{201C}park\u{201D}, \u{201C}security\u{201D}, or \u{201C}tag\u{201D}.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if query.isEmpty {
                        footer
                    }
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 36)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to ForgedBrew")
                .font(.system(size: 30, weight: .bold))
            Text("ForgedBrew is a clean, native macOS app that puts a friendly face on Homebrew \u{2014} the popular tool for installing software on a Mac. With ForgedBrew you can discover, install, update, organize, and look after everything on your Mac without ever opening Terminal.")
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("New here? Read straight through \u{2014} the sections below follow the app\u{2019}s sidebar from top to bottom. Or use the Table of Contents and the search box on the left to jump to anything. Each section includes a labeled diagram of the screen with numbered markers showing where to click.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // A few words of vocabulary, since everything else builds on it.
            VStack(alignment: .leading, spacing: 8) {
                ManualTermRow(term: "Cask", definition: "A Mac app installed by Homebrew (for example, VS Code or Firefox).")
                ManualTermRow(term: "Formula", definition: "A command-line tool installed by Homebrew (for example, git or wget).")
                ManualTermRow(term: "Tap", definition: "An extra source of Homebrew recipes beyond the official catalog.")
            }
            .padding(16)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 6)
            Text("ForgedBrew \u{2014} by Highfield-London \u{00B7} Apache License 2.0")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Homebrew is a separate open-source project (brew.sh). ForgedBrew is an independent front end and is not affiliated with or endorsed by Homebrew.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }
}

// MARK: - Small helpers

private struct ManualTermRow: View {
    let term: String
    let definition: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(term)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 64, alignment: .leading)
            Text(definition)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Section model

/// One self-contained chapter of the manual: a heading, prose, optional bullets,
/// callouts, and a wireframe diagram. The whole manual is just an array of these
/// (`ManualSection.all`), rendered top-to-bottom and filtered by the search box.
private struct ManualSection: Identifiable {
    // Stable id used as the scroll anchor and TOC key.
    let id: String
    let title: String
    let systemImage: String
    // Where this screen lives, shown as a breadcrumb under the title.
    let location: String?
    // Body paragraphs.
    let body: [String]
    // Bullet points (definitions, steps, option lists).
    let bullets: [ManualBullet]
    // Optional tip / note callout.
    let tip: String?
    // Optional caution callout.
    let warning: String?
    // The wireframe diagram to render for this section.
    let wireframe: ManualWireframe?

    init(
        id: String,
        title: String,
        systemImage: String,
        location: String? = nil,
        body: [String],
        bullets: [ManualBullet] = [],
        tip: String? = nil,
        warning: String? = nil,
        wireframe: ManualWireframe? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.location = location
        self.body = body
        self.bullets = bullets
        self.tip = tip
        self.warning = warning
        self.wireframe = wireframe
    }

    // Full-text match for the manual's search box.
    func matches(_ q: String) -> Bool {
        if title.lowercased().contains(q) { return true }
        if (location ?? "").lowercased().contains(q) { return true }
        if body.contains(where: { $0.lowercased().contains(q) }) { return true }
        if bullets.contains(where: { $0.matches(q) }) { return true }
        if (tip ?? "").lowercased().contains(q) { return true }
        if (warning ?? "").lowercased().contains(q) { return true }
        return false
    }
}

/// A single bullet point. Two shapes: a plain line, or a bold "lead" term
/// followed by an em-dash and description (the two initializers pick which).
private struct ManualBullet: Identifiable {
    let id = UUID()
    // Optional bold lead-in (e.g. an option name), then the description.
    let lead: String?
    let text: String

    init(_ lead: String?, _ text: String) {
        self.lead = lead
        self.text = text
    }
    init(_ text: String) {
        self.lead = nil
        self.text = text
    }

    func matches(_ q: String) -> Bool {
        (lead ?? "").lowercased().contains(q) || text.lowercased().contains(q)
    }
}

// Builds a styled line for a bullet that has a bold lead-in followed by an
// em-dash separator and the body text. Returns an AttributedString so it can be
// rendered with a single Text (string concatenation of Text was deprecated in
// macOS 26). The font set on the Text itself supplies the base size.
private func leadAttributed(lead: String, body: String) -> AttributedString {
    var leadPart = AttributedString(lead)
    leadPart.font = .system(size: 13.5, weight: .semibold)

    var separator = AttributedString("  \u{2014}  ")
    separator.font = .system(size: 13.5)
    separator.foregroundColor = .secondary

    var bodyPart = AttributedString(body)
    bodyPart.font = .system(size: 13.5)

    return leadPart + separator + bodyPart
}// MARK: - Section view

private struct ManualSectionView: View {
    let section: ManualSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Heading
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(section.title)
                    .font(.system(size: 22, weight: .bold))
            }

            if let location = section.location {
                HStack(spacing: 5) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 9))
                    Text(location)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
            }

            // Wireframe (drawn diagram of the screen)
            if let wf = section.wireframe {
                ManualWireframeView(spec: wf)
                    .padding(.vertical, 2)
            }

            // Body paragraphs
            ForEach(Array(section.body.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Bullets
            if !section.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(section.bullets) { bullet in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.tint)
                                .padding(.top, 6)
                            Group {
                                if let lead = bullet.lead {
                                    Text(leadAttributed(lead: lead, body: bullet.text))
                                        .font(.system(size: 13.5))
                                } else {
                                    Text(bullet.text).font(.system(size: 13.5))
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 2)
            }

            // Tip callout
            if let tip = section.tip {
                ManualCallout(kind: .tip, text: tip)
            }
            // Warning callout
            if let warning = section.warning {
                ManualCallout(kind: .warning, text: warning)
            }
        }
    }
}

// MARK: - Callout

private struct ManualCallout: View {
    enum Kind { case tip, warning }
    let kind: Kind
    let text: String

    private var icon: String { kind == .tip ? "lightbulb.fill" : "exclamationmark.triangle.fill" }
    private var tint: Color { kind == .tip ? .yellow : .orange }
    private var label: String { kind == .tip ? "Tip" : "Heads up" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Wireframe engine
//
// Dark-mode diagrams of each screen, drawn entirely with SwiftUI shapes and SF
// Symbols. A wireframe is described declaratively by a ManualWireframe spec and
// rendered by ManualWireframeView. Numbered annotation circles can be placed
// over any part of the diagram to point at exactly what to click; a small key
// underneath explains each number.
//
// The whole diagram is forced into dark mode (.environment(\.colorScheme,
// .dark)) regardless of the user's appearance, per the request that wireframes
// always be dark.

// A numbered marker drawn over the diagram, plus its explanation in the key.
private struct ManualMarker: Identifiable {
    let id = UUID()
    let number: Int
    // Position as a fraction (0...1) of the diagram's width/height.
    let x: CGFloat
    let y: CGFloat
    // Explanation shown in the numbered key below the diagram.
    let note: String
}

// Which screen to draw, the sidebar selection to highlight, the content layout,
// and the markers to overlay.
private struct ManualWireframe {
    enum Screen {
        case appFrame          // full window: sidebar + a content layout
        case sheet             // a centered modal sheet over a dimmed window
    }
    let screen: Screen
    // Sidebar row (by label) to show as selected. nil = none highlighted.
    let selectedRow: String?
    // The content area layout to draw.
    let content: ContentLayout
    // Caption under the diagram.
    let caption: String
    // Numbered markers + key.
    let markers: [ManualMarker]

    init(
        _ screen: Screen = .appFrame,
        selectedRow: String? = nil,
        content: ContentLayout,
        caption: String,
        markers: [ManualMarker] = []
    ) {
        self.screen = screen
        self.selectedRow = selectedRow
        self.content = content
        self.caption = caption
        self.markers = markers
    }
}

// What to draw in the main content pane of the app-frame wireframe.
private enum ContentLayout {
    case cards(title: String, subtitle: String?, rows: Int)        // generic list of card rows
    case grid(title: String, subtitle: String?, items: Int)        // tile grid (Home / Browse)
    case detail                                                    // a single package detail card
    case twoColumn(title: String, left: String, right: String)     // Maintenance: two columns of cards
    case settings(tabs: [String], selectedTab: Int, rows: Int)     // Settings tabs + cards
    case manual(blocks: Int)                                       // generic doc body
}

// The canonical dark-mode sidebar, mirroring the real app's order so the
// diagrams match what the user actually sees.
private struct WireSidebarRow: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let section: Bool          // true = section header (not selectable)
    let badge: Int?
    init(_ icon: String, _ label: String, section: Bool = false, badge: Int? = nil) {
        self.icon = icon
        self.label = label
        self.section = section
        self.badge = badge
    }
}

private let wireSidebar: [WireSidebarRow] = [
    WireSidebarRow("", "DISCOVER", section: true),
    WireSidebarRow("house", "Home"),
    WireSidebarRow("chart.line.uptrend.xyaxis", "Currently Trending"),
    WireSidebarRow("calendar", "3-Month Trend"),
    WireSidebarRow("crown", "Top Past Year"),
    WireSidebarRow("square.grid.2x2", "Browse All"),
    WireSidebarRow("", "ORGANIZATION", section: true),
    WireSidebarRow("heart", "Favorites"),
    WireSidebarRow("tag", "Notes & Tags"),
    WireSidebarRow("parkingsign.circle", "Parked", badge: 2),
    WireSidebarRow("", "INSTALLED AND UPDATES", section: true),
    WireSidebarRow("internaldrive", "Installed Apps & Formulae", badge: 84),
    WireSidebarRow("arrow.up.circle", "Homebrew Updates", badge: 6),
    WireSidebarRow("app.badge", "Mac Store / Other Apps", badge: 3),
    WireSidebarRow("", "MAINTENANCE", section: true),
    WireSidebarRow("wrench.and.screwdriver", "Maintenance"),
    WireSidebarRow("gearshape", "Settings"),
]

// Dark palette shared by all wireframe pieces.
private enum Wire {
    static let bg = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let panel = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let sidebar = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let stroke = Color.white.opacity(0.10)
    static let textHi = Color.white.opacity(0.88)
    static let textLo = Color.white.opacity(0.45)
    static let accent = Color(red: 0.35, green: 0.62, blue: 1.0)
    static let chip = Color.white.opacity(0.08)
    static let badge = Color(red: 0.95, green: 0.30, blue: 0.30)
    static let green = Color(red: 0.30, green: 0.80, blue: 0.45)
}

private struct ManualWireframeView: View {
    let spec: ManualWireframe

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            diagram
                .environment(\.colorScheme, .dark)

            // Caption
            Text(spec.caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Numbered key
            if !spec.markers.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(spec.markers.sorted { $0.number < $1.number }) { m in
                        HStack(alignment: .top, spacing: 8) {
                            MarkerBadge(number: m.number)
                            Text(m.note)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var diagram: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                switch spec.screen {
                case .appFrame:
                    appFrame
                case .sheet:
                    sheetFrame
                }

                // Annotation markers, positioned by fraction of the canvas.
                ForEach(spec.markers) { m in
                    MarkerBadge(number: m.number, ring: true)
                        .position(x: m.x * geo.size.width, y: m.y * geo.size.height)
                }
            }
        }
        .frame(height: 320)
        .background(Wire.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Wire.stroke, lineWidth: 1)
        )
    }

    // MARK: Full window (sidebar + content)

    private var appFrame: some View {
        VStack(spacing: 0) {
            wireTitleBar
            HStack(spacing: 0) {
                wireSidebarView
                    .frame(width: 188)
                Rectangle().fill(Wire.stroke).frame(width: 1)
                contentPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var wireTitleBar: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 9, height: 9)
            Circle().fill(Color(red: 1, green: 0.74, blue: 0.20)).frame(width: 9, height: 9)
            Circle().fill(Color(red: 0.27, green: 0.79, blue: 0.27)).frame(width: 9, height: 9)
            Spacer()
            // Search field in the toolbar.
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(Wire.textLo)
                Text("Search apps, casks, and formulae").font(.system(size: 9)).foregroundStyle(Wire.textLo)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(width: 220)
            .background(Wire.chip)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Wire.sidebar)
        .overlay(Rectangle().fill(Wire.stroke).frame(height: 1), alignment: .bottom)
    }

    private var wireSidebarView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(wireSidebar) { row in
                    if row.section {
                        Text(row.label)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Wire.textLo)
                            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 3)
                    } else {
                        let selected = row.label == spec.selectedRow
                        HStack(spacing: 7) {
                            Image(systemName: row.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(selected ? .white : Wire.textHi)
                                .frame(width: 14)
                            Text(row.label)
                                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? .white : Wire.textHi)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let b = row.badge {
                                Text("\(b)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Wire.badge)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selected ? Wire.accent.opacity(0.85) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Wire.sidebar)
    }

    // MARK: Content pane (varies by layout)

    @ViewBuilder
    private var contentPane: some View {
        switch spec.content {
        case let .cards(title, subtitle, rows):
            paneScaffold(title: title, subtitle: subtitle) {
                VStack(spacing: 7) {
                    ForEach(0..<rows, id: \.self) { _ in wireCardRow }
                }
            }
        case let .grid(title, subtitle, items):
            paneScaffold(title: title, subtitle: subtitle) {
                let cols = [GridItem(.adaptive(minimum: 78), spacing: 8)]
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(0..<items, id: \.self) { _ in wireTile }
                }
            }
        case .detail:
            detailPane
        case let .twoColumn(title, left, right):
            paneScaffold(title: title, subtitle: "Keep your Homebrew installation healthy") {
                HStack(alignment: .top, spacing: 10) {
                    wireColumn(header: left, tint: Wire.accent, rows: 3)
                    wireColumn(header: right, tint: Wire.green, rows: 3)
                }
            }
        case let .settings(tabs, selectedTab, rows):
            settingsPane(tabs: tabs, selected: selectedTab, rows: rows)
        case let .manual(blocks):
            paneScaffold(title: "Documentation", subtitle: nil) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<blocks, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Wire.chip)
                            .frame(height: 9)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func paneScaffold<Content: View>(
        title: String,
        subtitle: String?,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image("ForgedBrewLogo").resizable().scaledToFit().frame(width: 16, height: 16)
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Wire.textHi)
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 9)).foregroundStyle(Wire.textLo)
            }
            ScrollView(.vertical, showsIndicators: false) {
                content().padding(.top, 2)
            }
        }
        .padding(12)
    }

    private var wireCardRow: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6).fill(Wire.chip).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 3).fill(Wire.textHi.opacity(0.55)).frame(width: 96, height: 7)
                RoundedRectangle(cornerRadius: 3).fill(Wire.chip).frame(width: 150, height: 6)
            }
            Spacer()
            Text("Install")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Wire.accent).clipShape(Capsule())
        }
        .padding(8)
        .background(Wire.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var wireTile: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 8).fill(Wire.chip).frame(width: 34, height: 34)
            RoundedRectangle(cornerRadius: 3).fill(Wire.textHi.opacity(0.5)).frame(width: 50, height: 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Wire.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func wireColumn(header: String, tint: Color, rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: header == "Security" ? "shield.lefthalf.filled" : "wrench.and.screwdriver")
                    .font(.system(size: 10)).foregroundStyle(tint)
                Text(header).font(.system(size: 11, weight: .bold)).foregroundStyle(Wire.textHi)
            }
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 7) {
                    Circle().fill(tint.opacity(0.25)).frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        RoundedRectangle(cornerRadius: 3).fill(Wire.textHi.opacity(0.5)).frame(width: 70, height: 6)
                        RoundedRectangle(cornerRadius: 3).fill(Wire.chip).frame(width: 110, height: 5)
                    }
                    Spacer()
                    Text("Review").font(.system(size: 7, weight: .semibold)).foregroundStyle(tint)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(tint.opacity(0.15)).clipShape(Capsule())
                }
                .padding(7)
                .background(Wire.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Back button
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                Text("Back").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Wire.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Wire.accent.opacity(0.15)).clipShape(Capsule())

            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 12).fill(Wire.chip).frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(Wire.textHi.opacity(0.7)).frame(width: 120, height: 10)
                    RoundedRectangle(cornerRadius: 3).fill(Wire.chip).frame(width: 200, height: 7)
                    RoundedRectangle(cornerRadius: 3).fill(Wire.chip).frame(width: 160, height: 7)
                }
                Spacer()
                VStack(spacing: 5) {
                    Text("Install").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(Wire.accent).clipShape(Capsule())
                    HStack(spacing: 4) {
                        Image(systemName: "heart").font(.system(size: 9))
                        Image(systemName: "parkingsign.circle").font(.system(size: 9))
                    }.foregroundStyle(Wire.textLo)
                }
            }
            // Tag chips + note
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 3) {
                        Circle().fill([Wire.green, Wire.accent, Wire.badge][i]).frame(width: 6, height: 6)
                        RoundedRectangle(cornerRadius: 2).fill(Wire.textHi.opacity(0.4)).frame(width: 26, height: 5)
                        Image(systemName: "xmark").font(.system(size: 6)).foregroundStyle(Wire.textLo)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Wire.chip).clipShape(Capsule())
                }
                Text("+ Tag").font(.system(size: 8)).foregroundStyle(Wire.accent)
            }
            RoundedRectangle(cornerRadius: 6).fill(Wire.panel).frame(height: 44)
                .overlay(Text("Notes\u{2026}").font(.system(size: 9)).foregroundStyle(Wire.textLo), alignment: .topLeading)
            Spacer()
        }
        .padding(12)
    }

    private func settingsPane(tabs: [String], selected: Int, rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tab bar
            HStack(spacing: 6) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                    Text(t)
                        .font(.system(size: 9, weight: i == selected ? .semibold : .regular))
                        .foregroundStyle(i == selected ? .white : Wire.textLo)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(i == selected ? Wire.accent.opacity(0.85) : Wire.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
            }
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(Wire.textHi.opacity(0.55)).frame(width: 90, height: 7)
                        RoundedRectangle(cornerRadius: 3).fill(Wire.chip).frame(width: 170, height: 6)
                    }
                    Spacer()
                    Capsule().fill(Wire.green).frame(width: 26, height: 15)
                        .overlay(Circle().fill(.white).frame(width: 12, height: 12).padding(.leading, 11))
                }
                .padding(9)
                .background(Wire.panel).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
            // Save and Exit footer
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
                    Text("Save and Exit").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Wire.accent).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
    }

    // MARK: Sheet frame (modal over dimmed window)

    private var sheetFrame: some View {
        ZStack {
            appFrame.blur(radius: 2).opacity(0.4)
            Color.black.opacity(0.35)
            VStack(alignment: .leading, spacing: 10) {
                Text("Review").font(.system(size: 13, weight: .bold)).foregroundStyle(Wire.textHi)
                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(Wire.chip).frame(width: 14, height: 14)
                        RoundedRectangle(cornerRadius: 3).fill(Wire.textHi.opacity(0.5)).frame(width: 150, height: 7)
                        Spacer()
                    }
                }
                HStack {
                    Spacer()
                    Text("Cancel").font(.system(size: 9)).foregroundStyle(Wire.textLo)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                    Text("Apply").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Wire.accent).clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(16)
            .frame(width: 320)
            .background(Wire.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Wire.stroke, lineWidth: 1))
        }
    }
}

// MARK: - Marker badge

private struct MarkerBadge: View {
    let number: Int
    var ring: Bool = false

    var body: some View {
        ZStack {
            if ring {
                Circle()
                    .strokeBorder(Color(red: 1, green: 0.78, blue: 0.0), lineWidth: 2.5)
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            Circle()
                .fill(Color(red: 1, green: 0.62, blue: 0.0))
                .frame(width: 19, height: 19)
                .shadow(color: .black.opacity(0.4), radius: 1)
            Text("\(number)")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.black)
        }
    }
}

// MARK: - The manual content
//
// Sections follow the sidebar from top to bottom. Each carries a dark-mode
// wireframe of that screen with numbered markers and a key.

extension ManualSection {
    // The full, ordered manual. The first few cross-cutting sections (search,
    // Home, categories, detail card) are spelled out inline here; the rest are
    // appended from sidebar-grouped arrays below (organization, installed &
    // updates, maintenance, settings) to keep this declaration readable.
    static let all: [ManualSection] = [

        // ===== SEARCH (top of every screen) =====
        ManualSection(
            id: "search",
            title: "Search \u{2014} find anything fast",
            systemImage: "magnifyingglass",
            location: "Toolbar \u{00B7} top of every screen",
            body: [
                "The search field lives in the window\u{2019}s toolbar and is always available, no matter which screen you\u{2019}re on. Start typing and ForgedBrew searches the entire Homebrew catalog \u{2014} both Mac apps (casks) and command-line tools (formulae) \u{2014} at the same time, showing results grouped into \u{201C}Apps & Casks\u{201D} and \u{201C}Formulae.\u{201D}",
                "Search is not just matching names. For each item ForgedBrew looks across several fields, so you can find things by what they do, not only what they\u{2019}re called:"
            ],
            bullets: [
                ManualBullet("App / cask name", "the friendly display name, e.g. \u{201C}Visual Studio Code.\u{201D}"),
                ManualBullet("Homebrew token", "the exact identifier Homebrew uses, e.g. \u{201C}visual-studio-code.\u{201D}"),
                ManualBullet("Description", "the one-line summary of what the app does, so \u{201C}password manager\u{201D} or \u{201C}screenshot\u{201D} finds matching apps even if those words aren\u{2019}t in the name."),
                ManualBullet("Formula name & full name", "for command-line tools, including tap-qualified names."),
            ],
            tip: "Results rank exact and beginning-of-name matches first, then by how popular each item is (30-day installs), so the thing you\u{2019}re most likely after tends to sit at the top. Click any result to open its detail card, or use the inline Install button.",
            wireframe: ManualWireframe(
                selectedRow: "Home",
                content: .cards(title: "Results for \u{201C}browser\u{201D}", subtitle: "Apps & Casks \u{00B7} Formulae", rows: 4),
                caption: "Searching from the toolbar shows grouped results across the whole catalog.",
                markers: [
                    ManualMarker(number: 1, x: 0.62, y: 0.085, note: "Type here. The search field is in the toolbar on every screen."),
                    ManualMarker(number: 2, x: 0.86, y: 0.42, note: "Install straight from a result, or click the row to open its detail card."),
                ]
            )
        ),

        // ===== DISCOVER: HOME =====
        ManualSection(
            id: "home",
            title: "Home \u{2014} discover apps",
            systemImage: "house",
            location: "Sidebar \u{25B8} Discover \u{25B8} Home",
            body: [
                "Home is your starting point and the first thing you see. It surfaces featured apps and a curated mix so you can find great software without knowing its exact name. From any tile you can open the detail card or install with a click \u{2014} ForgedBrew runs Homebrew for you and shows progress.",
                "The Discover section of the sidebar gives you four more ways to explore the catalog:"
            ],
            bullets: [
                ManualBullet("Currently Trending", "apps gaining popularity in the Homebrew community right now."),
                ManualBullet("3-Month Trend", "what\u{2019}s been rising over the last quarter \u{2014} steadier signal than today\u{2019}s spikes."),
                ManualBullet("Top Past Year", "the most-installed apps over the past 12 months \u{2014} the proven favorites."),
                ManualBullet("Browse All", "the complete catalog in one grid, for when you just want to look around."),
            ],
            wireframe: ManualWireframe(
                selectedRow: "Home",
                content: .grid(title: "Home", subtitle: "Featured \u{00B7} Trending \u{00B7} Browse by category", items: 12),
                caption: "Home: a grid of app tiles with the Discover lists in the sidebar.",
                markers: [
                    ManualMarker(number: 1, x: 0.085, y: 0.18, note: "The Discover lists: Home, Currently Trending, 3-Month Trend, Top Past Year, Browse All."),
                    ManualMarker(number: 2, x: 0.55, y: 0.42, note: "Click any tile to open that app\u{2019}s detail card and install it."),
                ]
            )
        ),

        // ===== CATEGORIES & FORMULAE =====
        ManualSection(
            id: "categories",
            title: "Categories & Formulae",
            systemImage: "square.grid.2x2",
            location: "Sidebar \u{25B8} Categories / Formulae",
            body: [
                "Below Discover, the sidebar groups the whole catalog into Categories \u{2014} Developer Tools, Productivity, Internet & Browsers, Privacy & Security, Games, AI & ML, and more \u{2014} so you can drill into a topic and see just the apps that fit. Many categories expand into sub-categories for finer browsing.",
                "The Formulae section is the same idea for command-line tools. Apps (casks) and tools (formulae) are kept separate so the lists stay focused, but search always covers both at once."
            ],
            tip: "Not sure whether something is an app or a tool? Just search for it from the toolbar \u{2014} you don\u{2019}t need to pick the right category first.",
            wireframe: ManualWireframe(
                selectedRow: "Browse All",
                content: .grid(title: "Developer Tools", subtitle: "Browse by category", items: 12),
                caption: "Categories filter the grid to one topic; Formulae do the same for command-line tools.",
                markers: [
                    ManualMarker(number: 1, x: 0.085, y: 0.55, note: "Categories and Formulae live in the sidebar between Discover and Organization."),
                ]
            )
        ),

        // ===== DETAIL CARD =====
        ManualSection(
            id: "detail",
            title: "The detail card",
            systemImage: "rectangle.and.text.magnifyingglass",
            location: "Open by clicking any app or tool",
            body: [
                "Click any item anywhere in ForgedBrew to open its detail card \u{2014} the single place with everything about that package: icon, description, version, homepage, dependencies, license, and screenshots where available. This is also where you install, remove, favorite, park, tag, and take notes.",
            ],
            bullets: [
                ManualBullet("Install / Remove", "one button runs Homebrew for you, with live progress and a confirmation before anything is uninstalled."),
                ManualBullet("Favorite (heart)", "adds the app to your Favorites list for quick access later."),
                ManualBullet("Park", "holds this app\u{2019}s updates (see the Parked section)."),
                ManualBullet("Tags", "color-coded labels you create to organize apps your way. Click \u{201C}+ Tag\u{201D} to add one; remove it with the \u{00D7} on the chip."),
                ManualBullet("Notes", "a free-form note saved automatically per app \u{2014} reminders, license keys, why you installed it, anything."),
            ],
            tip: "The Back button (top-left of the card) highlights when you hover over it \u{2014} click it to return to wherever you came from.",
            wireframe: ManualWireframe(
                selectedRow: "Installed Apps & Formulae",
                content: .detail,
                caption: "A package\u{2019}s detail card: install/remove, favorite, park, tags, and notes all in one place.",
                markers: [
                    ManualMarker(number: 1, x: 0.30, y: 0.20, note: "Back button \u{2014} highlights on hover; returns to the previous screen."),
                    ManualMarker(number: 2, x: 0.86, y: 0.32, note: "Install or Remove. Below it: favorite (heart) and park."),
                    ManualMarker(number: 3, x: 0.40, y: 0.62, note: "Tags \u{2014} add color-coded labels; remove with the \u{00D7}."),
                    ManualMarker(number: 4, x: 0.55, y: 0.82, note: "Notes \u{2014} type anything; it saves automatically."),
                ]
            )
        ),
    ]
    + organizationSections
    + installedAndUpdatesSections
    + maintenanceSections
    + settingsSections
}

// MARK: - Organization sections
// The sidebar's "Organization" group: Favorites, Notes & Tags, Parked.
private let organizationSections: [ManualSection] = [

    ManualSection(
        id: "favorites",
        title: "Favorites",
        systemImage: "heart",
        location: "Sidebar \u{25B8} Organization \u{25B8} Favorites",
        body: [
            "Favorites is your personal shortlist. Click the heart on any detail card to add an app here, and it shows up in this list for one-click access later. Nothing is installed or changed \u{2014} it\u{2019}s purely your own bookmark of apps you care about.",
        ],
        wireframe: ManualWireframe(
            selectedRow: "Favorites",
            content: .cards(title: "Favorites", subtitle: "Apps you\u{2019}ve hearted", rows: 4),
            caption: "Favorites: a quick list of the apps you\u{2019}ve flagged with the heart.",
            markers: [
                ManualMarker(number: 1, x: 0.085, y: 0.40, note: "Find your hearted apps under Organization \u{25B8} Favorites."),
            ]
        )
    ),

    ManualSection(
        id: "notes-tags",
        title: "Notes & Tags",
        systemImage: "tag",
        location: "Sidebar \u{25B8} Organization \u{25B8} Notes & Tags",
        body: [
            "This is a combined view for organizing your library your own way, with two panes:",
        ],
        bullets: [
            ManualBullet("Notes", "every app you\u{2019}ve written a note for, in one place. Click an app\u{2019}s name to jump straight to its detail card."),
            ManualBullet("Tags", "all the color-coded tags you\u{2019}ve created, each with a count of how many packages carry it. Select a tag to see every package with that tag; click a package to open it."),
        ],
        tip: "Tags are created from a package\u{2019}s detail card. Use them however you like \u{2014} \u{201C}work,\u{201D} \u{201C}try later,\u{201D} \u{201C}essential,\u{201D} a client name \u{2014} and this screen becomes your custom index.",
        wireframe: ManualWireframe(
            selectedRow: "Notes & Tags",
            content: .twoColumn(title: "Notes & Tags", left: "Maintenance", right: "Security"),
            caption: "Notes & Tags: notes on the left, your tags and their packages on the right.",
            markers: [
                ManualMarker(number: 1, x: 0.085, y: 0.45, note: "Open Organization \u{25B8} Notes & Tags to see everything you\u{2019}ve annotated and tagged."),
            ]
        )
    ),

    ManualSection(
        id: "parked",
        title: "Parked \u{2014} hold an app\u{2019}s updates",
        systemImage: "parkingsign.circle",
        location: "Sidebar \u{25B8} Organization \u{25B8} Parked",
        body: [
            "Parking holds a package at its current version. A parked app is skipped by the Updates list and by Update All, so Homebrew never tries to upgrade it \u{2014} useful when a newer version breaks something or you simply want to stay put for a while.",
            "Park an app from its detail card or from the Park button next to it on an Updates screen. When you park, you can choose how the hold behaves \u{2014} for example, hold until you unpark, or hold for a set period that expires on its own.",
            "ForgedBrew keeps watching parked apps in the background. When a newer version appears (or a timed hold expires), the app resurfaces so you can decide. The sidebar badge next to Parked shows how many apps are currently held.",
        ],
        tip: "To resume updates, open the parked app and choose Unpark \u{2014} it rejoins the normal Updates flow immediately.",
        warning: "Parking only stops ForgedBrew/Homebrew from updating the app. An app that updates itself in the background (like a browser) can still update on its own.",
        wireframe: ManualWireframe(
            selectedRow: "Parked",
            content: .cards(title: "Parked", subtitle: "Updates held \u{2014} skipped by Update All", rows: 3),
            caption: "Parked: apps whose updates are held, with an Unpark option on each.",
            markers: [
                ManualMarker(number: 1, x: 0.10, y: 0.55, note: "The Parked badge shows how many apps are currently on hold."),
                ManualMarker(number: 2, x: 0.86, y: 0.34, note: "Open a parked app to Unpark it and resume updates."),
            ]
        )
    ),
]

// MARK: - Installed and Updates sections
// The sidebar's "Installed and Updates" group: Installed, Homebrew Updates,
// and Mac Store / Other Apps.
private let installedAndUpdatesSections: [ManualSection] = [

    ManualSection(
        id: "installed",
        title: "Installed Apps & Formulae",
        systemImage: "internaldrive",
        location: "Sidebar \u{25B8} Installed and Updates",
        body: [
            "This is everything Homebrew manages on your Mac right now \u{2014} your installed apps (casks) and command-line tools (formulae) in one searchable list. ForgedBrew reads the real state of your system from Homebrew, so this always reflects what\u{2019}s actually installed.",
            "Use it to review what you have, search or filter within it, open any item\u{2019}s detail card, and remove things you no longer need. The badge on the sidebar row shows the total installed count.",
        ],
        wireframe: ManualWireframe(
            selectedRow: "Installed Apps & Formulae",
            content: .cards(title: "Installed Apps & Formulae", subtitle: "Everything Homebrew manages here", rows: 5),
            caption: "Installed: your real, current Homebrew apps and tools.",
            markers: [
                ManualMarker(number: 1, x: 0.115, y: 0.62, note: "The badge shows how many packages are installed."),
                ManualMarker(number: 2, x: 0.55, y: 0.40, note: "Click any row to open its detail card; remove from there."),
            ]
        )
    ),

    ManualSection(
        id: "homebrew-updates",
        title: "Homebrew Updates",
        systemImage: "arrow.up.circle",
        location: "Sidebar \u{25B8} Installed and Updates \u{25B8} Homebrew Updates",
        body: [
            "This screen lists every Homebrew package that has a newer version available. Update them one at a time with the Update button on each row, or update everything at once with Update All. ForgedBrew runs Homebrew and shows live progress; up-to-date items are clearly marked.",
            "Each row also has a Park button so you can hold a specific app back instead of updating it (see Parked). The sidebar badge shows how many updates are waiting \u{2014} and it never counts parked apps.",
        ],
        bullets: [
            ManualBullet("Update", "upgrade just that package to its newest version."),
            ManualBullet("Update All", "upgrade every listed package in one go (parked apps are skipped)."),
            ManualBullet("Park", "hold this package at its current version and skip it in Update All."),
        ],
        tip: "The number badge in the sidebar \u{2014} and on the Dock icon \u{2014} reflects available updates with parked apps already excluded, so it only counts things you can actually act on.",
        wireframe: ManualWireframe(
            selectedRow: "Homebrew Updates",
            content: .cards(title: "Homebrew Updates", subtitle: "6 updates available \u{00B7} Update All", rows: 4),
            caption: "Homebrew Updates: per-app Update and Park buttons, plus Update All.",
            markers: [
                ManualMarker(number: 1, x: 0.135, y: 0.55, note: "Badge = number of available updates (parked apps excluded)."),
                ManualMarker(number: 2, x: 0.86, y: 0.30, note: "Update a single app \u{2014} or use Update All at the top."),
                ManualMarker(number: 3, x: 0.86, y: 0.55, note: "Park holds an app at its current version."),
            ]
        )
    ),

    ManualSection(
        id: "mac-other-apps",
        title: "Mac Store / Other Apps",
        systemImage: "app.badge",
        location: "Sidebar \u{25B8} Installed and Updates \u{25B8} Mac Store / Other Apps",
        body: [
            "Not every app on your Mac comes from Homebrew. This screen finds updates for apps you installed outside Homebrew \u{2014} Mac App Store apps and direct downloads \u{2014} by checking several sources: Sparkle (the common self-update framework), GitHub releases, the App Store, and Homebrew\u{2019}s cask catalog (which covers apps like VS Code that update themselves).",
            "It\u{2019}s a single place to see what\u{2019}s out of date across your whole Mac, not just Homebrew. Use Rescan to check again at any time. App Store apps open in the App Store to finish updating; others can be updated in place.",
        ],
        bullets: [
            ManualBullet("Rescan", "re-check all your apps for newer versions."),
            ManualBullet("Park", "hold an app\u{2019}s update here too \u{2014} it reappears when a newer version ships or its hold expires."),
        ],
        tip: "To read exact App Store version numbers, install the small \u{201C}mas\u{201D} helper (run \u{201C}brew install mas\u{201D}). Without it, App Store apps still open in the App Store to update \u{2014} ForgedBrew just can\u{2019}t show their version number.",
        wireframe: ManualWireframe(
            selectedRow: "Mac Store / Other Apps",
            content: .cards(title: "Mac Store / Other Apps", subtitle: "Updates for apps outside Homebrew \u{00B7} Rescan", rows: 4),
            caption: "Mac Store / Other Apps: updates for App Store and direct-download apps.",
            markers: [
                ManualMarker(number: 1, x: 0.155, y: 0.69, note: "Badge counts non-Homebrew app updates."),
                ManualMarker(number: 2, x: 0.86, y: 0.30, note: "Update an app, or Rescan to check again."),
            ]
        )
    ),
]

// MARK: - Maintenance sections (detailed)

private let maintenanceSections: [ManualSection] = [

    ManualSection(
        id: "maintenance",
        title: "Maintenance \u{2014} overview",
        systemImage: "wrench.and.screwdriver",
        location: "Sidebar \u{25B8} Maintenance \u{25B8} Maintenance",
        body: [
            "The Maintenance screen gathers every housekeeping and safety tool in one place, so you can keep your Mac tidy and your Homebrew install healthy. At the top you\u{2019}ll see a Health score summarizing how things look. Below it the tools are arranged in two columns \u{2014} Maintenance (blue) on the left for upkeep, and Security (green) on the right for safety checks \u{2014} followed by Cache and Backup & Restore.",
            "Every tool explains what it does before it changes anything, shows you exactly what it found, and asks for confirmation. Actions that need elevated permissions will prompt for your macOS password \u{2014} ForgedBrew never makes silent changes.",
        ],
        warning: "Some tools (clearing caches, removing quarantine, adopting apps) may ask you to grant ForgedBrew Full Disk Access in System Settings the first time. If a tool reports a permission error, grant access and try again.",
        wireframe: ManualWireframe(
            selectedRow: "Maintenance",
            content: .twoColumn(title: "Maintenance", left: "Maintenance", right: "Security"),
            caption: "Maintenance: a Health score on top, then Maintenance (blue) and Security (green) tool columns.",
            markers: [
                ManualMarker(number: 1, x: 0.43, y: 0.30, note: "Maintenance column (blue): Disk Usage, Doctor, Adopt Apps, Orphaned Packages, Duplicates."),
                ManualMarker(number: 2, x: 0.80, y: 0.30, note: "Security column (green): Security Scan, Vulnerability Scan, Remove Quarantine, Trust Maintenance."),
                ManualMarker(number: 3, x: 0.86, y: 0.34, note: "Each tool has a Review/Scan button that explains itself before doing anything."),
            ]
        )
    ),

    ManualSection(
        id: "maintenance-tools",
        title: "Maintenance tools (the blue column)",
        systemImage: "wrench.and.screwdriver",
        location: "Maintenance \u{25B8} Maintenance column",
        body: [
            "These tools keep your Homebrew setup lean and correct:",
        ],
        bullets: [
            ManualBullet("Disk Usage", "see how much space Homebrew uses, broken down by location \u{2014} so you know where the space is going before you clean anything."),
            ManualBullet("Doctor", "runs Homebrew\u{2019}s built-in \u{201C}brew doctor\u{201D} and lists any issues it finds with your installation, in plain language."),
            ManualBullet("Adopt Apps into Homebrew", "finds apps you installed manually that Homebrew also offers, and lets Homebrew start managing them \u{2014} so they\u{2019}re tracked and updatable from now on."),
            ManualBullet("Clean Up Orphaned Packages", "removes formulae that were only kept as dependencies for something you\u{2019}ve since removed \u{2014} reclaiming space safely."),
            ManualBullet("Duplicates", "finds apps or tools installed more than once (for example, both manually and via Homebrew) so you can resolve the conflict."),
        ],
        tip: "Start with Disk Usage and Doctor \u{2014} they only report, never change anything, so they\u{2019}re a safe way to see the state of things before you act.",
        wireframe: ManualWireframe(
            selectedRow: "Maintenance",
            content: .twoColumn(title: "Maintenance", left: "Maintenance", right: "Security"),
            caption: "The Maintenance column: Disk Usage, Doctor, Adopt Apps, Orphaned Packages, and Duplicates.",
            markers: [
                ManualMarker(number: 1, x: 0.43, y: 0.32, note: "Each card names the tool, explains it, and offers a Review button."),
                ManualMarker(number: 2, x: 0.55, y: 0.34, note: "Tools that change things show you what they found and ask before doing it."),
            ]
        )
    ),

    ManualSection(
        id: "security",
        title: "Security \u{2014} the green column",
        systemImage: "shield.lefthalf.filled",
        location: "Maintenance \u{25B8} Security column",
        body: [
            "The Security column helps you confirm the apps on your Mac are signed, trusted, and free of known vulnerabilities. These checks are read-only unless you choose to act on what they find.",
        ],
        bullets: [
            ManualBullet("Security Scan", "checks each installed app\u{2019}s code signature and Gatekeeper status (using macOS\u{2019}s own codesign and spctl) and flags anything unsigned or untrusted."),
            ManualBullet("Vulnerability Scan", "compares your installed versions against the public OSV.dev vulnerability database (CVEs) and tells you if any installed software has a known security issue and should be updated."),
            ManualBullet("Remove Quarantine", "lists files macOS has flagged as downloaded (the \u{201C}quarantine\u{201D} attribute that triggers the \u{201C}are you sure you want to open this?\u{201D} prompt) and lets you clear that flag on apps you trust."),
            ManualBullet("Trust Maintenance", "reviews your installed apps for Gatekeeper readiness ahead of macOS\u{2019}s upcoming tightening of trust rules, so you\u{2019}re not surprised by apps that stop opening."),
        ],
        tip: "Run the Security Scan and Vulnerability Scan periodically. They only report \u{2014} you stay in control of what, if anything, to update or trust.",
        warning: "Only remove quarantine from apps you actually trust. The quarantine flag is a safety check; clearing it tells macOS to stop warning you about that app.",
        wireframe: ManualWireframe(
            selectedRow: "Maintenance",
            content: .twoColumn(title: "Maintenance", left: "Maintenance", right: "Security"),
            caption: "The Security column: Security Scan, Vulnerability Scan, Remove Quarantine, and Trust Maintenance.",
            markers: [
                ManualMarker(number: 1, x: 0.80, y: 0.30, note: "Security Scan & Vulnerability Scan \u{2014} read-only checks of signatures and known CVEs."),
                ManualMarker(number: 2, x: 0.80, y: 0.55, note: "Remove Quarantine & Trust Maintenance \u{2014} review what macOS flagged before acting."),
            ]
        )
    ),

    ManualSection(
        id: "cache-backup",
        title: "Cache, Backup & Restore",
        systemImage: "externaldrive",
        location: "Maintenance \u{25B8} bottom",
        body: [
            "At the bottom of the Maintenance screen are two more areas:",
        ],
        bullets: [
            ManualBullet("Cache", "two cards \u{2014} ForgedBrew\u{2019}s own media/image cache, and Homebrew\u{2019}s download cache. Clearing either frees disk space; the files are re-downloaded only if needed later."),
            ManualBullet("Backup & Restore (Brewfile)", "export your entire Homebrew setup to a Brewfile \u{2014} a simple text list of everything you have \u{2014} or reinstall everything from one. Perfect for moving to a new Mac or rebuilding after a wipe."),
        ],
        tip: "Export a Brewfile now and again. It\u{2019}s a tiny file that captures your whole setup, so a new Mac is one \u{201C}restore\u{201D} away from feeling like home.",
        wireframe: ManualWireframe(
            selectedRow: "Maintenance",
            content: .twoColumn(title: "Maintenance", left: "Maintenance", right: "Security"),
            caption: "Cache (two cards) and Backup & Restore (Brewfile) sit at the bottom of Maintenance.",
            markers: [
                ManualMarker(number: 1, x: 0.62, y: 0.72, note: "Cache: clear ForgedBrew\u{2019}s media cache or Homebrew\u{2019}s download cache to free space."),
                ManualMarker(number: 2, x: 0.62, y: 0.88, note: "Brewfile: export your setup or reinstall everything from a saved file."),
            ]
        )
    ),
]

// MARK: - Settings sections (detailed)

private let settingsSections: [ManualSection] = [

    ManualSection(
        id: "settings",
        title: "Settings \u{2014} overview",
        systemImage: "gearshape",
        location: "Sidebar \u{25B8} Maintenance \u{25B8} Settings (or \u{2318},)",
        body: [
            "Open Settings from the sidebar or with \u{2318}, from the menu bar. It\u{2019}s organized into four tabs across the top, and a single Save and Exit button at the bottom closes the window gracefully (your changes are saved live as you make them \u{2014} the button is just a tidy way out).",
        ],
        bullets: [
            ManualBullet("General & Updates", "appearance, startup behavior, and how updates work."),
            ManualBullet("App Locations", "where ForgedBrew looks for installed apps when it scans."),
            ManualBullet("APIs", "an optional key for richer app screenshots."),
            ManualBullet("About", "version, the User Manual, license, and how to support ForgedBrew."),
        ],
        wireframe: ManualWireframe(
            selectedRow: "Settings",
            content: .settings(tabs: ["General & Updates", "App Locations", "APIs", "About"], selectedTab: 0, rows: 3),
            caption: "Settings: four tabs across the top, Save and Exit at the bottom.",
            markers: [
                ManualMarker(number: 1, x: 0.45, y: 0.20, note: "Switch tabs: General & Updates, App Locations, APIs, About."),
                ManualMarker(number: 2, x: 0.86, y: 0.86, note: "Save and Exit closes the window \u{2014} changes are already saved."),
            ]
        )
    ),

    ManualSection(
        id: "general-updates",
        title: "General & Updates",
        systemImage: "gearshape",
        location: "Settings \u{25B8} General & Updates",
        body: [
            "This tab controls how ForgedBrew looks, how it starts, and how it handles updates. It has several cards:",
        ],
        bullets: [
            ManualBullet("Appearance", "choose Light, Dark, or System. This matches the quick light/dark toggle at the bottom of the sidebar."),
            ManualBullet("Load on startup", "open ForgedBrew automatically when you log in to your Mac (macOS may ask you to confirm the login item the first time)."),
            ManualBullet("Keep in Dock", "show the ForgedBrew icon in the Dock all the time, with the number of available updates as a badge (like Mail or Messages). Turn it off to keep the Dock clear \u{2014} opening from the menu bar then shows a Dock icon only while the window is open."),
            ManualBullet("Show in menu bar", "add a ForgedBrew icon to the menu bar with the update count beside it and a menu to open or quit. When this is on and ForgedBrew launches at login, it starts quietly in the menu bar \u{2014} click the icon and choose \u{201C}Open ForgedBrew\u{201D} to bring up the window."),
            ManualBullet("ForgedBrew updates", "keep the app itself current. ForgedBrew also checks automatically in the background; use \u{201C}Check for ForgedBrew Updates\u{2026}\u{201D} to check on demand."),
            ManualBullet("Self-updating apps", "some apps (Office, Chrome, Claude) update themselves, so Homebrew normally leaves them off the list. Turn this on and ForgedBrew will check them too \u{2014} you may see them even when current; updating simply reinstalls the latest."),
        ],
        tip: "The Dock and menu-bar badges always show the same number you see in the sidebar: available updates with parked apps excluded.",
        wireframe: ManualWireframe(
            selectedRow: "Settings",
            content: .settings(tabs: ["General & Updates", "App Locations", "APIs", "About"], selectedTab: 0, rows: 4),
            caption: "General & Updates: appearance, startup (Dock / menu bar), and update behavior.",
            markers: [
                ManualMarker(number: 1, x: 0.45, y: 0.20, note: "You\u{2019}re on the General & Updates tab."),
                ManualMarker(number: 2, x: 0.83, y: 0.42, note: "Toggles for Load on startup, Keep in Dock, Show in menu bar, and Self-updating apps."),
            ]
        )
    ),

    ManualSection(
        id: "app-locations",
        title: "App Locations",
        systemImage: "folder",
        location: "Settings \u{25B8} App Locations",
        body: [
            "Here you choose where ForgedBrew looks for installed apps when it scans \u{2014} which it does for adopting apps, clearing quarantine, security checks, and measuring sizes.",
            "The two standard folders \u{2014} Applications (all users) and My Applications (this user) \u{2014} are on by default. If you keep apps somewhere else, add up to five custom folders. Your custom list is saved on your Mac, so it survives updates and restarts.",
        ],
        wireframe: ManualWireframe(
            selectedRow: "Settings",
            content: .settings(tabs: ["General & Updates", "App Locations", "APIs", "About"], selectedTab: 1, rows: 3),
            caption: "App Locations: the folders ForgedBrew scans, plus up to five custom ones.",
            markers: [
                ManualMarker(number: 1, x: 0.49, y: 0.20, note: "The App Locations tab."),
                ManualMarker(number: 2, x: 0.55, y: 0.45, note: "Standard folders are on by default; add custom folders if your apps live elsewhere."),
            ]
        )
    ),

    ManualSection(
        id: "apis",
        title: "APIs (optional image search)",
        systemImage: "key",
        location: "Settings \u{25B8} APIs",
        body: [
            "ForgedBrew shows app screenshots from each app\u{2019}s GitHub README and repository preview image with no setup needed. On this tab you can optionally add a personal SerpApi key, which lets ForgedBrew also search the web for screenshots of apps that don\u{2019}t publish one on GitHub.",
            "The key is stored only on your Mac and is never bundled with the app or shared. SerpApi has a free tier, and ForgedBrew caches results, so a small quota goes a long way. This is entirely optional \u{2014} the app works fully without it.",
        ],
        wireframe: ManualWireframe(
            selectedRow: "Settings",
            content: .settings(tabs: ["General & Updates", "App Locations", "APIs", "About"], selectedTab: 2, rows: 2),
            caption: "APIs: an optional SerpApi key for richer app screenshots.",
            markers: [
                ManualMarker(number: 1, x: 0.52, y: 0.20, note: "The APIs tab \u{2014} optional, stored only on your Mac."),
            ]
        )
    ),

    ManualSection(
        id: "about",
        title: "About \u{2014} version, manual & support",
        systemImage: "info.circle",
        location: "Settings \u{25B8} About",
        body: [
            "The About tab shows the app version, the Homebrew version ForgedBrew detected, the creator, and the license (Apache 2.0). It\u{2019}s also where you\u{2019}ll always find a button to open this User Manual, and a friendly, never-required way to support ForgedBrew with a small donation if you find it useful.",
            "You\u{2019}ll also see this manual automatically the first time you install ForgedBrew and after each update, via the Welcome window \u{2014} but it\u{2019}s always one click away here.",
        ],
        wireframe: ManualWireframe(
            selectedRow: "Settings",
            content: .settings(tabs: ["General & Updates", "App Locations", "APIs", "About"], selectedTab: 3, rows: 3),
            caption: "About: version info, Open User Manual, license, and an optional Donate button.",
            markers: [
                ManualMarker(number: 1, x: 0.56, y: 0.20, note: "The About tab."),
                ManualMarker(number: 2, x: 0.55, y: 0.50, note: "Open User Manual any time, and support ForgedBrew if you\u{2019}d like."),
            ]
        )
    ),
]