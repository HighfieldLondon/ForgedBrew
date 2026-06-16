import SwiftUI
import AppKit
import WebKit
import Foundation

// Small regex helper used by the README cleaner to strip HTML / badge / link
// markup that AttributedString can't render. Returns the original string
// unchanged if the pattern fails to compile.
extension String {
    func regexReplace(_ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return self }
        let range = NSRange(startIndex..<endIndex, in: self)
        return re.stringByReplacingMatches(
            in: self, options: [], range: range, withTemplate: template
        )
    }
}

// MARK: - Sub-views

// A lightweight live web view used in the More Info tab for packages that have
// NO README and no other long-form text (e.g. CLOP). Rather than show the same
// short description that already appears in Overview, we render the project's
// actual homepage inside a scrollable WKWebView so More Info stays genuinely
// distinct and rich. This deliberately shows the REAL site (not extracted body
// text, which a prior iteration found produced nav/badge garbage on most sites).
// A WKWebView subclass that does NOT consume vertical scroll-wheel events.
// Instead it forwards every scroll gesture up the responder chain to the
// enclosing AppKit scroll view that backs the SwiftUI ScrollView, so the
// OUTER ScrollView is the only thing that scrolls.
//
// Why this is needed: simply hiding the scrollbar (hasVerticalScroller = false)
// does NOT stop a WKWebView from intercepting scroll-wheel events internally —
// it still "eats" the gesture once its own content can scroll, which trapped the
// user at the bottom of the web view and stranded the header above. Overriding
// scrollWheel to pass the event to nextResponder makes the web view fully
// scroll-transparent; combined with sizing it to its full content height, the
// single outer ScrollView handles everything. One scroller = no trap.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Forward to the enclosing scroll view (the SwiftUI ScrollView's backing
        // NSScrollView) so the outer view scrolls. nextResponder walks up the
        // responder chain to reach it.
        nextResponder?.scrollWheel(with: event)
    }
}

struct HomepageWebView: NSViewRepresentable {
    let url: URL
    // Reports the page's full content height back to SwiftUI so the web view can
    // be sized to fit its content. CRITICAL: the web view is scroll-transparent
    // (see PassthroughWebView) and sized to its full content height, so the
    // single outer SwiftUI ScrollView handles all scrolling.
    // Nesting a scrollable WKWebView inside the outer ScrollView caused a
    // scroll-trap bug — once the user scrolled to the bottom of the web view,
    // the outer scroll could no longer move and the header above became
    // unreachable until the tab was switched. One scroller = no trap.
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // transparent so it blends with the card
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Reload only when the target URL actually changes (e.g. switching cards
        // reuses the representable). Avoids a reload loop on every layout pass.
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: HomepageWebView
        init(_ parent: HomepageWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            // Re-measure shortly after load: many pages finish layout / load
            // async assets (images, fonts) after didFinish, changing height.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak webView] in
                guard let webView else { return }
                self.measure(webView)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak webView] in
                guard let webView else { return }
                self.measure(webView)
            }
        }

        private func measure(_ webView: WKWebView) {
            webView.evaluateJavaScript(
                "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
            ) { value, _ in
                guard let h = value as? CGFloat, h > 0 else { return }
                // Clamp so a pathologically tall page can't blow up the layout;
                // the outer ScrollView still scrolls within this bound.
                let clamped = min(max(h, 200), 6000)
                if abs(clamped - self.parent.contentHeight) > 1 {
                    self.parent.contentHeight = clamped
                }
            }
        }
    }
}

// A filled, clearly-active action button used in the detail header. Each action
// (Install, Homepage, Copy Command) passes its own `tint` so the buttons read as
// distinct, tappable controls rather than faded secondary text. `isProminent`
// renders a solid color fill; when false (e.g. an already-installed app) it uses
// a soft tinted fill so the color still reads but the control feels secondary.
struct DetailActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isProminent: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                // White label on every action button — reads clearer than
                // tinted text, including on the softer (non-prominent)
                // Homepage / Copy Command buttons, whose fill is darkened
                // below so white text stands out.
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    // On hover, prominent buttons settle to a softer, deeper
                    // fill rather than staying near full saturation — so the
                    // amber Update button no longer flares too bright.
                    // Hover is more pronounced now: prominent buttons brighten
                    // noticeably (0.92 -> 1.0), and the soft Homepage / Copy
                    // Command buttons use a much deeper base fill (0.62) so the
                    // white label is clearly legible, jumping to 0.82 on hover.
                    isProminent
                        ? AnyShapeStyle(tint.opacity(isHovering ? 1.0 : 0.92))
                        : AnyShapeStyle(tint.opacity(isHovering ? 0.82 : 0.62)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    // A brighter ring appears on hover (both modes) for a more
                    // pronounced hover cue; at rest the fill carries the shape
                    // so the buttons stay clean.
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            Color.white.opacity(isHovering ? 0.35 : 0.0),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct StatCard: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }
}

// Install/uninstall progress HUD shown at the bottom of a cask detail card.
//
// Mirrors the per-row status shown on the Updates and Installed screens: a
// plain-language phase line (Downloading… / Installing… / Uninstalling… /
// Cleaning up… / Done) with a matching icon and a bright-green flowing progress
// bar while the operation is in flight, plus a red failure banner on error.
// Deliberately shows NO raw brew/terminal output — the user asked for our own
// friendly status here, consistent with every other install/uninstall surface.
struct InstallHUD: View {
    let appName: String
    let progress: InstallProgress
    // When true, render as a compact inline panel (no bottom-floating
    // padding/transition) so it can sit directly below the action buttons,
    // in place of the brew-install command box. Default false = the
    // original bottom-floating HUD behavior.
    var inline: Bool = false

    // Tint for the status icon + label: accent while in flight, green on
    // success, red on failure (matches UpdatesView / InstalledView).
    private var statusTint: Color {
        switch progress.phase {
        // An uninstall reads in red the whole way through (and on success),
        // so removing an app is visually distinct from installing one.
        case .finished: return progress.isUninstall ? .red : .green
        case .failed:   return .red
        case .uninstalling: return .red
        default:        return progress.isUninstall ? .red : .accentColor
        }
    }

    // Failure message, if this operation failed.
    private var failureMessage: String? {
        if case .failed(let message) = progress.phase { return message }
        return nil
    }

    // The headline reflects the operation kind so the user sees which app is
    // being worked on; the phase line below carries the live detail.
    private var headline: String {
        switch progress.phase {
        case .uninstalling:  return "Uninstalling \(appName)"
        // After an uninstall completes the success state should read
        // "X is uninstalled" — not "X is ready", which only fits an install.
        case .finished:      return progress.isUninstall ? "\(appName) is uninstalled"
                                                          : "\(appName) is ready"
        case .failed:        return "\(appName) failed"
        default:             return "Installing \(appName)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.system(size: 13, weight: .semibold))

            // Phase line — same icon + label vocabulary used on the Updates and
            // Installed rows. The red failure case is carried by the banner
            // below, so we suppress the failed phase here to avoid duplicating
            // the error.
            if failureMessage == nil {
                HStack(spacing: 6) {
                    if progress.isActive {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                    Image(systemName: progress.statusSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusTint)
                    Text(progress.statusLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(statusTint)
                    Spacer(minLength: 0)
                }
            }

            // Bright-green flowing bar the whole time the operation is in flight
            // (download → verify → install → cleanup, or uninstall). Hidden once
            // the operation reaches Done/Failed.
            if progress.isActive {
                GreenDashProgressBar(
                    tint: progress.isUninstall
                        ? .red
                        : Color(red: 0.16, green: 0.86, blue: 0.30)
                )
                .frame(height: 4)
            }

            // Red failure banner with the full error, mirroring the Updates row.
            if let failureMessage, !failureMessage.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                    Text(failureMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(inline ? 0.08 : 0.15), radius: inline ? 8 : 20, y: inline ? 3 : 8)
        // Bottom-floating chrome only applies to the original overlay HUD;
        // the inline variant sits flush below the buttons.
        .padding(.horizontal, inline ? 0 : 24)
        .padding(.bottom, inline ? 0 : 24)
        .transition(inline ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }
}

struct ReadmeView: View {
    let text: String?
    let fallback: String?
    // True while the richer Overview sources (Wikipedia blurb / README / full
    // article / homepage meta) are still being fetched. When set AND we don't
    // yet have that richer `text`, we show a brief "Loading…" note instead of
    // flashing the bare fallback description — mirroring the Screenshots tab.
    var isLoading: Bool = false
    // True when we ALREADY have something to show (typically the short Homebrew
    // description) but a richer description (Wikipedia blurb / README) is still
    // being fetched in the background. We render the current text immediately
    // and add a subtle inline "Loading fuller description…" hint underneath, so
    // nothing is hidden but it's clear more is on the way.
    var isUpgrading: Bool = false

    var body: some View {
        if isLoading, (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Fetching the best description for this package — this can take a few seconds.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .padding(.horizontal)
        } else if let content = (text ?? fallback)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            // Render the Overview text with the same proportional, Markdown-aware
            // engine the More Info tab uses (AboutView.blocks) instead of raw
            // monospaced terminal-style text. Headings, bold/italic, links,
            // inline code, and bullet lists are all styled; plain prose just
            // reads as clean body text.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AboutView.blocks(from: content)) { block in
                        block.view
                    }
                    if isUpgrading {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading fuller description…")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 4)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            Text("No description available.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

// Empty state shown when a cask has no image we can display. When we have an
// "about" blurb (GitHub README intro or the Homebrew description) we show it as
// a readable text panel instead of a bare "nothing here" message — turning the
// otherwise-empty tab into something useful. Falls back to the plain icon
// message only when there's no text at all.
struct ScreenshotsPlaceholderView: View {
    var aboutText: String? = nil

    var body: some View {
        if let aboutText, !aboutText.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("About this app")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(aboutText)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
                Text("No screenshots were published for this app, so here's its description.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
            .padding()
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No screenshot available")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("This app doesn't publish screenshots we can show here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .padding(.horizontal)
        }
    }
}

// Renders cached screenshots (resolved from the GitHub README or the web-image
// search fallback and stored on disk). Shows the honest "No screenshot
// available" empty state when none were found.
struct ScreenshotsView: View {
    let urls: [URL]
    var aboutText: String? = nil
    // When true, the images shown are a rendered snapshot of the app's homepage
    // (a fallback used when no real screenshots exist) rather than actual app
    // screenshots — so we caption them as a "Homepage preview".
    var isHomepagePreview: Bool = false
    // True while the detail view is still resolving media. We show a clear
    // "Loading…" state instead of the empty placeholder so a slow screenshot
    // resolve (cache miss → network fetch → page render) reads as still-working.
    var isLoading: Bool = false

    var body: some View {
        // Show the friendly "Loading…" note whenever media is still resolving and
        // we don't yet have any screenshot URLs to display. (Once URLs arrive,
        // each AsyncImage shows its own per-image placeholder spinner while its
        // bytes download, so we hand off to the gallery branch below.)
        if isLoading && urls.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading screenshots…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Fetching images and the app's page — this can take a few seconds.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .padding(.horizontal)
        } else if urls.isEmpty {
            ScreenshotsPlaceholderView(aboutText: aboutText)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if isHomepagePreview {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Homepage preview")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(urls, id: \.self) { url in
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.12))
                                    .frame(width: 320, height: 200)
                                    .overlay { ProgressView() }
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
                            case .failure:
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.12))
                                    .frame(width: 320, height: 200)
                                    .overlay {
                                        Image(systemName: "photo.badge.exclamationmark")
                                            .font(.system(size: 28))
                                            .foregroundStyle(.tertiary)
                                    }
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
                }
                .padding()
            }
            }
        }
    }
}

// Renders the project's GitHub README in the detail card. The README text is
// fetched (and cached) during the detail load pass and handed in here; while
// that resolve is still in flight we show a "Loading…" note (mirroring the
// Screenshots tab) so a slow fetch reads as still-working rather than empty.
// The content is rendered as Markdown where possible (headings, bold, links,
// lists) and falls back to plain monospaced text if Markdown parsing fails.
struct AboutView: View {
    // The About panel renders identically for casks and formulae. Rather than
    // depend on CaskMetadata directly (formulae use a different model), it holds
    // the handful of plain facts the panel shows; two initializers adapt a
    // CaskMetadata or a FormulaMetadata into those fields.
    let displayName: String
    let desc: String?
    let alsoKnownAs: [String]        // extra name aliases (cask.name.dropFirst)
    let versionText: String?
    let autoUpdatesText: String?     // nil hides the row (formulae: managed by Homebrew)
    let minMacOS: String?            // casks only
    let alsoInstalls: [String]       // bundled dependencies to surface
    let deprecated: Bool
    let homepage: String?
    let kindLabel: String            // "app" / "command-line tool" — for the empty-state copy

    let markdown: String?
    let repoURL: URL?
    var license: String? = nil
    var isLoading: Bool = false
    var webBlurb: String? = nil
    var webBlurbLoading: Bool = false
    // True when `webBlurb` is a Wikipedia summary (vs the app's own homepage
    // text). Gates the "Summary from Wikipedia" caption so it never mislabels
    // homepage/brew-desc text. Defaults to true to preserve prior behavior for
    // any caller that hasn't been updated.
    var blurbIsWikipedia: Bool = true
    // Describes where the long-form `markdown` came from, so the footer link
    // reads correctly. Defaults to the README/GitHub behavior; the full
    // Wikipedia-article path overrides these.
    var markdownSourceName: String = "README on GitHub"
    var markdownSourceURL: URL? = nil
    // True when the long-form `markdown` is the project's GitHub README. When
    // false, the long-form is a fallback (homepage meta text or a Wikipedia
    // article) — in that case, if a valid homepage exists we render the live
    // site instead, since the fallback text is short and duplicates Overview
    // (the CLOP problem). Defaults to true to preserve the README-first path.
    var isReadme: Bool = true

    // Measured full content height of the live homepage web view (when the
    // no-README homepage branch is shown). The web view's own scrolling is
    // disabled and it is sized to this height so the single outer ScrollView
    // handles all scrolling — fixing the scroll-trap bug where reaching the
    // bottom of a nested scrollable web view stranded the header above.
    @State private var homepageContentHeight: CGFloat = 600

    // Cask initializer — preserves the original call site behavior.
    init(cask: CaskMetadata,
         markdown: String?,
         repoURL: URL?,
         license: String? = nil,
         isLoading: Bool = false,
         webBlurb: String? = nil,
         webBlurbLoading: Bool = false,
         markdownSourceName: String = "README on GitHub",
         markdownSourceURL: URL? = nil,
         isReadme: Bool = true,
         blurbIsWikipedia: Bool = true) {
        self.displayName = cask.displayName
        self.desc = cask.desc
        self.alsoKnownAs = cask.name.count > 1 ? Array(cask.name.dropFirst()) : []
        self.versionText = cask.version
        self.autoUpdatesText = cask.autoUpdates == true
            ? "Yes \u{2014} the app updates itself"
            : "No \u{2014} managed by Homebrew"
        self.minMacOS = cask.dependsOn?.macos?.greaterThanOrEqualTo?.first
        self.alsoInstalls = cask.dependsOn?.cask ?? []
        self.deprecated = cask.deprecated
        self.homepage = cask.homepage
        self.kindLabel = "app"
        self.markdown = markdown
        self.repoURL = repoURL
        self.license = license
        self.isLoading = isLoading
        self.webBlurb = webBlurb
        self.webBlurbLoading = webBlurbLoading
        self.markdownSourceName = markdownSourceName
        self.markdownSourceURL = markdownSourceURL
        self.isReadme = isReadme
        self.blurbIsWikipedia = blurbIsWikipedia
    }

    // Formula initializer — formulae have no auto-update flag or macOS floor, so
    // those rows are omitted; dependencies are surfaced as "Also installs".
    init(formula: FormulaMetadata,
         markdown: String?,
         repoURL: URL?,
         license: String? = nil,
         isLoading: Bool = false,
         webBlurb: String? = nil,
         webBlurbLoading: Bool = false,
         markdownSourceName: String = "README on GitHub",
         markdownSourceURL: URL? = nil,
         isReadme: Bool = true,
         blurbIsWikipedia: Bool = true) {
        self.displayName = formula.name
        self.desc = formula.desc
        self.alsoKnownAs = []
        self.versionText = formula.displayVersion
        self.autoUpdatesText = nil
        self.minMacOS = nil
        self.alsoInstalls = formula.dependencies
        self.deprecated = formula.deprecated || formula.disabled
        self.homepage = formula.homepage
        self.kindLabel = "command-line tool"
        self.markdown = markdown
        self.repoURL = repoURL
        self.license = license
        self.isLoading = isLoading
        self.webBlurb = webBlurb
        self.webBlurbLoading = webBlurbLoading
        self.markdownSourceName = markdownSourceName
        self.markdownSourceURL = markdownSourceURL
        self.isReadme = isReadme
        self.blurbIsWikipedia = blurbIsWikipedia
    }

    var body: some View {
        // Still resolving and nothing to show yet → friendly loading state.
        if isLoading && (markdown?.isEmpty ?? true) {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Fetching details from the project's GitHub repository — this can take a few seconds.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .padding(.horizontal)
        } else if isReadme, let md = markdown, Self.isSubstantialReadme(md) {
            // The project has a real, substantial README — render it (the
            // strongest signal). A README that is only a sentence or two is NOT
            // treated as substantial; it falls through to the live web view
            // below so More Info stays richer than a one-line blurb.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.blocks(from: md)) { block in
                        block.view
                    }
                    if let sourceURL = markdownSourceURL ?? repoURL {
                        Divider().padding(.vertical, 4)
                        Link(destination: sourceURL) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.forward.square")
                                Text("View this \(markdownSourceName)")
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else if let homeURL = Self.validHomepageURL(homepage) {
            // No README (the long-form, if any, is just homepage/Wikipedia
            // fallback text), but the package has a homepage. Rather
            // than show the SAME short description that already leads Overview
            // (the CLOP problem: Overview == More Info), render the project's
            // ACTUAL homepage live in a scrollable web view. This keeps More
            // Info genuinely distinct and rich even for packages with no docs.
            // A compact facts header sits above it; the site fills the rest.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    descriptionSection
                    factsSection
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                Divider()
                // The whole tab body lives inside the card's single outer
                // ScrollView. The web view's OWN scrolling is disabled and it is
                // sized to its measured full content height, so the outer
                // ScrollView scrolls the entire page — no nested-scroll trap.
                HomepageWebView(url: homeURL, contentHeight: $homepageContentHeight)
                    .frame(height: homepageContentHeight)
                    .frame(maxWidth: .infinity)
            }
        } else {
            // No README and no usable homepage. Show the rich "About" panel: a
            // description (Wikipedia blurb when we found one, else the Homebrew
            // description), any fallback long-form text we did resolve
            // (e.g. a Wikipedia article) so it isn't lost, key Homebrew facts we
            // already hold (no extra network), and links.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    descriptionSection
                    if let md = markdown,
                       !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(Self.blocks(from: md)) { block in
                            block.view
                        }
                        if let sourceURL = markdownSourceURL ?? repoURL {
                            Link(destination: sourceURL) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.forward.square")
                                    Text("View this \(markdownSourceName)")
                                }
                                .font(.system(size: 12, weight: .medium))
                            }
                        }
                    }
                    factsSection
                    linksSection
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
    }

    // Whether a piece of long-form text is a genuinely substantial README
    // worth rendering in place, versus just a sentence or two (which we'd
    // rather replace with the live homepage). Heuristics, in order:
    //   • Markdown structure (a heading, a list, a fenced code block, or a
    //     link) almost always means a real README — keep it.
    //   • Otherwise fall back to length: real READMEs run long; a one- or
    //     two-sentence blurb is short. ~320 chars ≈ 2–3 sentences.
    static func isSubstantialReadme(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Structural markers strongly indicate a real README.
        let hasHeading = trimmed.contains("\n#") || trimmed.hasPrefix("#")
        let hasList = trimmed.contains("\n- ") || trimmed.contains("\n* ")
            || trimmed.contains("\n+ ") || trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
        let hasCodeFence = trimmed.contains("```")
        let hasLink = trimmed.contains("](")
        if hasHeading || hasList || hasCodeFence || hasLink { return true }
        // No structure — judge by length. A couple of sentences is not enough.
        return trimmed.count >= 320
    }

    // Returns a loadable http(s) homepage URL, or nil. Guards against empty /
    // malformed / non-web homepages so the web-view branch only triggers when
    // we actually have a site to show.
    static func validHomepageURL(_ homepage: String?) -> URL? {
        guard let raw = homepage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // The lead descriptive paragraph. Prefers the web (Wikipedia) blurb, then
    // the cask's Homebrew description. Shows a small inline spinner while the
    // blurb is still being fetched and we have nothing else.
    @ViewBuilder private var descriptionSection: some View {
        let desc = (self.desc ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let blurb = (webBlurb ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Priority: the curated Homebrew one-liner leads (always app-specific,
        // e.g. "Slide over browser"); the homepage/Wikipedia blurb only fills in
        // when there is no brew desc. This keeps a name-collision Wikipedia
        // article from ever overriding the real, on-topic description.
        let showingBlurb = desc.isEmpty && !blurb.isEmpty
        let text = !desc.isEmpty ? desc : (!blurb.isEmpty ? blurb : nil)
        VStack(alignment: .leading, spacing: 6) {
            Text(displayName)
                .font(.system(size: 17, weight: .semibold))
            if let text {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if showingBlurb && blurbIsWikipedia {
                    Text("Summary from Wikipedia")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else if webBlurbLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up a description\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No description available for this \(kindLabel).")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // Compact key/value facts pulled straight from the Homebrew metadata we
    // already have in hand — zero extra network. Only rows we actually know
    // are shown.
    @ViewBuilder private var factsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, 8)
            if !alsoKnownAs.isEmpty {
                aboutRow("Also known as", alsoKnownAs.joined(separator: ", "))
            }
            if let v = versionText, !v.isEmpty { aboutRow("Latest version", v) }
            if let autoUpdatesText { aboutRow("Auto-updates", autoUpdatesText) }
            if let lic = license, !lic.isEmpty { aboutRow("License", lic) }
            if let minOS = minMacOS {
                aboutRow("Requires macOS", "\(minOS) or later")
            }
            if !alsoInstalls.isEmpty {
                aboutRow("Also installs", alsoInstalls.joined(separator: ", "))
            }
            aboutRow("Source", repoURL != nil ? "Open source (GitHub)" : "Closed source / vendor-distributed")
            if deprecated {
                aboutRow("Status", "Deprecated \u{2014} no longer maintained in Homebrew")
            }
        }
    }

    // Homepage + repository links.
    @ViewBuilder private var linksSection: some View {
        let homepageURL = homepage.flatMap { URL(string: $0) }
        if homepageURL != nil || repoURL != nil {
            VStack(alignment: .leading, spacing: 6) {
                Divider().padding(.bottom, 2)
                if let homepageURL {
                    Link(destination: homepageURL) {
                        HStack(spacing: 6) {
                            Image(systemName: "house")
                            Text("Visit the website")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                }
                if let repoURL {
                    Link(destination: repoURL) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.forward.square")
                            Text("View the source on GitHub")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                }
            }
        }
    }

    // One label/value line in the facts list.
    @ViewBuilder private func aboutRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }

    // A rendered README block (one logical line/paragraph), kept Identifiable so
    // ForEach can diff them. We render line-by-line so headings, list items,
    // code fences, and prose each get appropriate styling without pulling in a
    // full Markdown engine. Inline Markdown (bold, italics, links, inline code)
    // is parsed per line via AttributedString, falling back to plain text.
    struct ReadmeBlock: Identifiable {
        let id: Int
        let raw: String
        let kind: Kind
        enum Kind { case h1, h2, h3, bullet, code, rule, blank, text }

        @ViewBuilder var view: some View {
            switch kind {
            case .rule:
                Divider().padding(.vertical, 2)
            case .blank:
                Spacer().frame(height: 2)
            case .code:
                Text(raw)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            case .h1:
                inline(AboutView.stripHeading(raw))
                    .font(.system(size: 19, weight: .bold))
                    .padding(.top, 6)
            case .h2:
                inline(AboutView.stripHeading(raw))
                    .font(.system(size: 16, weight: .bold))
                    .padding(.top, 4)
            case .h3:
                inline(AboutView.stripHeading(raw))
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 2)
            case .bullet:
                HStack(alignment: .top, spacing: 6) {
                    Text("•").font(.system(size: 13)).foregroundStyle(.secondary)
                    inline(AboutView.stripBullet(raw)).font(.system(size: 13))
                }
            case .text:
                inline(raw).font(.system(size: 13))
            }
        }

        // Parses inline Markdown (links/bold/italic/inline-code) for a single
        // line; falls back to the raw string if parsing fails. fixedSize lets
        // long lines wrap naturally instead of truncating.
        @ViewBuilder private func inline(_ s: String) -> some View {
            if let attributed = try? AttributedString(
                markdown: s,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            ) {
                Text(attributed)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(s)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func stripHeading(_ s: String) -> String {
        var t = s
        while t.hasPrefix("#") { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func stripBullet(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "+ "] where t.hasPrefix(prefix) {
            return String(t.dropFirst(prefix.count))
        }
        return t
    }

    // Cleans a single non-code README line of the markup that AttributedString
    // can't render and that otherwise leaks through as literal text (the
    // "embedded characters" the user saw): raw HTML tags, HTML comments,
    // reference-style links/badges, images, and link reference definitions.
    // Inline links/bold/italic in standard [text](url) form are LEFT intact so
    // AttributedString can still render them.
    static func cleanReadmeLine(_ line: String) -> String {
        var s = line

        // 1) Drop HTML comments  <!-- ... -->.
        s = s.regexReplace("<!--.*?-->", with: "")

        // 2) Linked badge images — an image wrapped in a link, the dominant
        //    shape of README badge rows:  [![alt][ref]][ref]  or
        //    [![alt](url)](url). Remove the whole construct.
        s = s.regexReplace("\\[!\\[[^\\]]*\\](\\([^)]*\\)|\\[[^\\]]*\\])\\](\\([^)]*\\)|\\[[^\\]]*\\])", with: "")

        // 3) Plain images — we don't render images inline. Inline ![alt](url)
        //    and reference ![alt][ref] forms.
        s = s.regexReplace("!\\[[^\\]]*\\]\\([^)]*\\)", with: "")
        s = s.regexReplace("!\\[[^\\]]*\\]\\[[^\\]]*\\]", with: "")

        // 4) Strip ALL HTML tags (<h1 ...>, <img ...>, </div>, <a ...>, <br>,
        //    etc.). Text BETWEEN tags is kept; only the tags themselves go.
        s = s.regexReplace("<[^>]+>", with: "")

        // 5) Reference-style links [text][ref] -> text. Before the bare-[text]
        //    pass so the trailing [ref] is consumed too.
        s = s.regexReplace("\\[([^\\]]+)\\]\\[[^\\]]*\\]", with: "$1")

        // 6) Bare [text] NOT followed by "(" or "[" -> text. Real inline links
        //    [text](url) are left intact for AttributedString to render.
        s = s.regexReplace("\\[([^\\]]+)\\](?![\\(\\[])", with: "$1")

        // 7) Empty brackets left where an image/badge was removed.
        s = s.regexReplace("\\[\\s*\\]", with: "")

        // 8) A second bare-[text] pass catches reference labels that became
        //    danglers after their image was removed (still skipping real links).
        s = s.regexReplace("\\[([^\\]]+)\\](?!\\()", with: "$1")

        // 9) Decode the common HTML entities that remain.
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (e, r) in entities { s = s.replacingOccurrences(of: e, with: r) }

        // 10) Collapse the whitespace runs left behind by removed markup.
        s = s.regexReplace("[ \\t]{2,}", with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    // True for lines that are link/image REFERENCE DEFINITIONS, e.g.
    //   [img-version-badge]: https://img.shields.io/...
    // These never render and should be dropped wholesale.
    static func isReferenceDefinition(_ trimmed: String) -> Bool {
        return trimmed.range(of: "^\\[[^\\]]+\\]:\\s*\\S+",
                             options: .regularExpression) != nil
    }

    // Splits the README into renderable blocks. Code fences (```) toggle a
    // verbatim code block; otherwise each line is cleaned of HTML / badges /
    // reference links and then classified as a heading, bullet, horizontal
    // rule, blank, or prose. HTML comment lines and reference definitions are
    // dropped.
    static func blocks(from markdown: String) -> [ReadmeBlock] {
        var out: [ReadmeBlock] = []
        var inFence = false
        var id = 0
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                out.append(ReadmeBlock(id: id, raw: line, kind: .code)); id += 1
                continue
            }
            // Drop link/image reference definitions outright.
            if Self.isReferenceDefinition(trimmed) {
                continue
            }
            // Headings keep their leading #'s through cleaning so the classifier
            // below still recognizes them; everything else is cleaned now.
            let isHeadingLine = trimmed.hasPrefix("#")
            if isHeadingLine {
                // Clean the heading TEXT but preserve the # prefix.
                let hashes = String(trimmed.prefix(while: { $0 == "#" }))
                let rest = String(trimmed.dropFirst(hashes.count))
                trimmed = hashes + " " + Self.cleanReadmeLine(rest)
                trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            } else {
                trimmed = Self.cleanReadmeLine(trimmed)
            }
            // A line that was pure HTML / badges collapses to empty after
            // cleaning — render it as a blank separator instead of literal junk.
            if trimmed.isEmpty {
                out.append(ReadmeBlock(id: id, raw: "", kind: .blank)); id += 1
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                out.append(ReadmeBlock(id: id, raw: "", kind: .rule)); id += 1
                continue
            }
            if trimmed.hasPrefix("### ") {
                out.append(ReadmeBlock(id: id, raw: trimmed, kind: .h3)); id += 1
            } else if trimmed.hasPrefix("## ") {
                out.append(ReadmeBlock(id: id, raw: trimmed, kind: .h2)); id += 1
            } else if trimmed.hasPrefix("# ") {
                out.append(ReadmeBlock(id: id, raw: trimmed, kind: .h1)); id += 1
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                out.append(ReadmeBlock(id: id, raw: trimmed, kind: .bullet)); id += 1
            } else {
                out.append(ReadmeBlock(id: id, raw: trimmed, kind: .text)); id += 1
            }
        }
        return out
    }
}

struct DependenciesView: View {
    let caskDeps: [String]?

    var body: some View {
        if let deps = caskDeps, !deps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(deps, id: \.self) { dep in
                    HStack {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(.secondary)
                        Text(dep).font(.system(size: 13, design: .monospaced))
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        } else {
            Text("No dependencies")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

// MARK: - DetailView

struct DetailView: View {
    let cask: CaskMetadata
    var onBack: (() -> Void)? = nil

    @State private var viewModel: DetailViewModel
    @Environment(AppDataService.self) var appData
    // Drives the "Add to favorites" hint beside the header star, mirroring the
    // hover behavior on the summary card.
    @State private var isHeaderHovered = false
    // Drives the back button hover highlight.
    @State private var isBackHovered = false

    // A single Equatable snapshot of THIS cask's installed state, so .onChange
    // re-syncs the button whenever presence/version/outdated changes — even when
    // the total installed count stays the same (e.g. an in-place update).
    private var installedStateKey: String {
        if let pkg = appData.installedByToken[cask.token] {
            return "in|\(pkg.installedVersion ?? "?")|\(pkg.isOutdated)"
        }
        return "out"
    }

    // A coarse snapshot of THIS cask's in-flight operation phase, so .onChange
    // can react the instant an install/uninstall finishes — independent of the
    // installed-set refresh. Used to force a re-sync (and, if needed, a second
    // refresh) the moment the operation completes, so the button flips to
    // "Installed" right away instead of only after an app restart.
    private var progressPhaseKey: String {
        guard let p = appData.installProgress[cask.token] else { return "none" }
        switch p.phase {
        case .finished:        return "finished"
        case .failed:          return "failed"
        default:               return "active"
        }
    }

    init(cask: CaskMetadata, onBack: (() -> Void)? = nil) {
        self.cask = cask
        self.onBack = onBack
        self._viewModel = State(initialValue: DetailViewModel(cask: cask))
    }

    var body: some View {
        // The top of the card (back, header, trust, stats, and the tab picker)
        // is FIXED; only the selected tab's body scrolls beneath it. This keeps
        // the app name, action buttons, and tab selector always visible while
        // the user scrolls a long README or a live homepage web view.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if let onBack {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            // Solid white label so it reads as a filled button,
                            // not tinted text.
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                // A clearly visible, darker-green filled pill.
                                // Default state already reads as a real button;
                                // hover brightens it noticeably for obvious
                                // feedback. Capsule + accent green keeps it on
                                // brand.
                                Capsule()
                                    // Lighter, softer green at rest; bold full
                                    // green on hover for a clearly pronounced
                                    // change of state.
                                    .fill(Color.accentColor
                                          .opacity(isBackHovered ? 1.0 : 0.47))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.accentColor
                                        .opacity(isBackHovered ? 1.0 : 0.47),
                                        lineWidth: isBackHovered ? 1.5 : 1)
                            )
                            // Stronger glow lift on hover for obvious affordance.
                            .shadow(color: Color.accentColor.opacity(isBackHovered ? 0.55 : 0.0),
                                    radius: isBackHovered ? 8 : 0, y: 1)
                            .scaleEffect(isBackHovered ? 1.03 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .onHover { isBackHovered = $0 }
                    .animation(.easeOut(duration: 0.12), value: isBackHovered)
                    .padding(.top, 2)
                }
                headerSection
                trustBanner
                Divider()
                statsRow
                Divider()
                tabPicker
            }
            .padding(.horizontal)
            // Small top inset so the Back button isn't jammed against the
            // window's title bar / navigation title (kept tight to give the
            // card more vertical real estate). Nudged from 10 -> 6 to lift the
            // Back pill a touch higher; the button's own .padding(.top, 2)
            // above stays as the safety cushion so it never tucks under the
            // title bar (a problem we are deliberately avoiding).
            .padding(.top, 6)
            .padding(.bottom, 12)
            // Solid opaque background so the scrolling tab content below cannot
            // ghost through the fixed header (was showing a translucent bar
            // across the top of the card). Crucially the background EXTENDS UP
            // into the title-bar / toolbar zone (ignoresSafeArea top) so it fills
            // the macOS 26 automatic scroll-edge fade band. Without this the
            // fade material composites over the header icon + title, producing
            // the reported "black/opaque bar" at the very top of the card. The
            // solid fill defeats the ghost entirely.
            .background(
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea(edges: .top)
            )

            // Only the tab content scrolls; the info column on the right is
            // pinned OUTSIDE the scroll view so it never moves. Because the
            // ScrollView now wraps only the left column, its scroll indicator
            // lands at the right edge of the content — i.e. just to the LEFT of
            // the info box — so the user can see when the text is scrollable.
            HStack(alignment: .top, spacing: 24) {
                ScrollView {
                    tabBody
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .hardScrollEdge(.top)
                // The right-side info column sits in its OWN ScrollView so its
                // intrinsic content height can NEVER drive the window size.
                // It previously used .fixedSize(vertical: true), which makes a
                // view claim its full intrinsic height and ignore the parent
                // proposal; in an alignment-top HStack that pinned the whole row
                // to the info column's tall content height, and with
                // windowResizability contentMinSize the window grew to fit it
                // whenever a taller detail card opened. Letting it fill and
                // scroll internally means the row claims only the height the
                // window already offers, so navigation no longer resizes it.
                ScrollView {
                    infoSidebar
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.never)
                .frame(width: 260)
                .padding(.trailing)
                .padding(.top)
            }
            // Fill available height instead of letting content dictate it, so
            // the card never reports a min height larger than the window.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // (The live install/uninstall progress now renders inline, directly
        // below the action buttons in headerSection, replacing the
        // brew-install command box while an operation is in flight — instead
        // of the old bottom-floating overlay HUD.)
        .task {
            // Sync the installed flags from the shared in-memory set FIRST, before
            // the slow load() (download-size probe + GitHub + screenshots). The
            // shared set is the source of truth and is usually already populated
            // when a detail card opens, so the Install/Installed button renders
            // correctly on the very first frame instead of briefly (or, on a
            // launch race, persistently) showing "Install" for an installed app
            // — the exact bug seen opening Claude Code from Home right after
            // launch. load() below will only ever UPGRADE this to installed; it
            // never downgrades what we set here.
            viewModel.syncInstalledState(from: appData)
            await viewModel.load(db: appData.db, api: appData.api)
            await viewModel.loadNote(db: appData.db)
            // Re-sync from the shared installed set in case an install/uninstall
            // (possibly started from another view) completed while we were away.
            viewModel.syncInstalledState(from: appData)
            // Check whether this installed app is at risk from the upcoming
            // Homebrew cask-quarantine change, so the trust banner can appear.
            await viewModel.checkTrust(cli: appData.cli)
        }
        // Keep the installed flags in sync whenever the shared installed set
        // changes (e.g. the manager finished an operation started here or
        // elsewhere), so the button flips Install↔Installed without a reload.
        // Watch THIS cask's installed entry, not just the total count: an
        // in-place change (e.g. outdated -> up-to-date after an update, where
        // the installed count is unchanged) must still flip the button. The
        // observed key folds the fields the UI cares about into one Equatable
        // string so any of them changing — presence, version, outdated — fires.
        .onChange(of: installedStateKey) {
            viewModel.syncInstalledState(from: appData)
            // An install/uninstall may have changed trust risk — re-check.
            Task { await viewModel.checkTrust(cli: appData.cli) }
        }
        // Belt-and-suspenders for the "didn't flip to Installed until restart"
        // bug: the moment THIS cask's operation reports finished, re-sync the
        // installed flags from the shared set. If the just-installed token still
        // isn't present (a brew metadata write can lag the stream's EOF by a
        // beat), force one more refreshInstalled so the button and the Installed
        // list reflect it immediately rather than after an app relaunch.
        .onChange(of: progressPhaseKey) {
            guard progressPhaseKey == "finished" else { return }
            viewModel.syncInstalledState(from: appData)
            if appData.installedByToken[cask.token] == nil {
                Task {
                    await appData.refreshInstalled()
                    viewModel.syncInstalledState(from: appData)
                }
            }
            Task { await viewModel.checkTrust(cli: appData.cli) }
        }
        // Admin-password prompt for privileged casks (those that install/uninstall
        // via a `pkg`, e.g. apps that need root). The shared install manager raises
        // a SudoRequest when an operation needs a password; without this sheet the
        // detail card would set `.needsPassword` and hang forever ("Waiting for
        // admin password…") because no UI was bound to present the prompt. Mirrors
        // the InstalledView / UpdatesView sheets.
        .sheet(item: sudoRequestBinding) { request in
            SudoPasswordSheet(
                request: request,
                validate: { await appData.validateSudoPassword($0) }
            ) { password in
                appData.provideSudoPassword(password, for: request)
            }
        }
    }

    // Binding over the shared install manager's outstanding sudo request, so the
    // password sheet presents via `.sheet(item:)`. Setting it to nil (sheet
    // dismiss) is treated as a cancel and clears the queued operation.
    private var sudoRequestBinding: Binding<SudoRequest?> {
        Binding(
            get: { appData.pendingSudoRequest },
            set: { newValue in
                if newValue == nil, let current = appData.pendingSudoRequest {
                    appData.provideSudoPassword(nil, for: current)
                }
            }
        )
    }

    // MARK: - Trust banner (upcoming Homebrew change)
    //
    // Shown only when this installed cask fails Gatekeeper AND still carries the
    // com.apple.quarantine flag — the apps that will stop opening once Homebrew
    // drops its cask quarantine workaround (support ends Sept 1, 2026). A calm,
    // non-alarming banner that explains why the app may not launch and offers a
    // one-tap fix (xattr -d com.apple.quarantine), so the user doesn't have to
    // discover the Maintenance tab. While trustRisk is nil the banner collapses
    // to nothing — healthy and not-installed apps never see it.
    @ViewBuilder
    private var trustBanner: some View {
        if let risk = viewModel.trustRisk {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("This app may not open")
                        .font(.system(size: 13, weight: .semibold))
                    Text("macOS can’t verify \(risk.appName) — \(risk.reason.lowercased()). An upcoming Homebrew change (Sept 1, 2026) means apps like this won’t open on their own. If it won’t launch, tell macOS to trust it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if viewModel.trusting {
                    ProgressView().scaleEffect(0.7).frame(width: 90)
                } else {
                    Button {
                        Task { await viewModel.trustThisApp(cli: appData.cli) }
                    } label: {
                        Text("Trust This App")
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
        } else if viewModel.trustJustCleared {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                Text("Trusted — macOS will now let this app open.")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(14)
            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.green.opacity(0.30), lineWidth: 1)
            )
        }
    }

    // MARK: - Header Section

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                AppIconView(token: cask.token, displayName: cask.displayName, homepage: cask.homepage, size: 92)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(cask.displayName)
                            .font(.largeTitle.bold())
                        // Favorite star — sits right beside the name; same
                        // component + hover hint as the summary card.
                        FavoriteButton(token: cask.token, showHint: isHeaderHovered, hintTrailing: true)
                            .scaleEffect(1.3)
                        Spacer(minLength: 0)
                    }
                    Text(cask.token)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    // Deprecation badge. Homebrew marks casks it no longer
                    // recommends as deprecated (the formula/cask is on its way
                    // out — unmaintained, superseded, or slated for removal).
                    // Surface it prominently right under the token so the user
                    // sees the staleness signal before deciding to install.
                    if cask.deprecated {
                        Label("Deprecated", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange, in: Capsule())
                            .help("Homebrew has deprecated this cask. It may be unmaintained, superseded, or scheduled for removal — installing it is discouraged.")
                            .padding(.top, 2)
                    }
                    if let desc = cask.desc {
                        Text(desc)
                            .font(.body)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onHover { isHeaderHovered = $0 }

            HStack(spacing: 12) {
                installButton
                // Prefer the app's real homepage; only fall back to the resolved
                // GitHub repo when there's no homepage. (The dedicated GitHub Page
                // button below links the repo, so Homepage shouldn't duplicate it.)
                if let homepageURL = cask.homepage.flatMap(URL.init(string:)) ?? cask.githubURL {
                    DetailActionButton(
                        title: "Homepage",
                        systemImage: "safari.fill",
                        tint: .blue,
                        isProminent: false
                    ) {
                        NSWorkspace.shared.open(homepageURL)
                    }
                }

                // Opens this cask's page on formulae.brew.sh (the canonical
                // Homebrew listing: description, versions, analytics, the cask
                // source link). Always available since every cask has a token.
                // Our "View on formulae.brew.sh" action.
                if let brewPageURL = DetailViewModel.homebrewPageURL(forCask: cask.token) {
                    DetailActionButton(
                        title: "Homebrew Page",
                        systemImage: "mug.fill",
                        tint: ActionColors.homebrew, // Homebrew brown; prominent = white text
                        isProminent: true
                    ) {
                        NSWorkspace.shared.open(brewPageURL)
                    }
                }

                // GitHub Page — only when we resolved a source repo for this
                // cask (the homepage when it's a github.com URL, the repo
                // recovered from the download URL, or a host-matched search
                // result). Opens the repository so the user can inspect source,
                // issues, and releases. Hidden entirely for closed-source apps
                // where there's no repo to link to.
                if let repoURL = viewModel.resolvedRepoURL ?? cask.githubURL {
                    DetailActionButton(
                        title: "GitHub Page",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        tint: ActionColors.github,
                        isProminent: true
                    ) {
                        NSWorkspace.shared.open(repoURL)
                    }
                }

                DetailActionButton(
                    title: viewModel.didCopyCommand ? "Copied!" : "Copy Command",
                    systemImage: viewModel.didCopyCommand ? "checkmark" : "doc.on.doc.fill",
                    tint: .gray,
                    isProminent: false
                ) {
                    viewModel.copyInstallCommand()
                }

                // Explicit Uninstall button, shown only when the app is
                // installed. Pushed to the far right of the action row (via the
                // Spacer below) so this destructive action stays out of the way
                // of the everyday Install/Homepage/Copy Command buttons rather
                // than sitting flush against them. This is a clearly labeled
                // alternative to the "Installed" pill's tap-to-remove behavior
                // (which users didn't discover). Disabled while any operation
                // for this cask is in flight.
                if viewModel.isInstalled {
                    Spacer(minLength: 16)
                    DetailActionButton(
                        title: "Uninstall",
                        systemImage: "trash",
                        tint: ActionColors.destructive
                    ) {
                        viewModel.startUninstall(appData: appData)
                    }
                    .disabled(appData.isOperationInFlight(token: cask.token))
                }
            }

            // Live operation progress floats right below the action buttons.
            // While an install/uninstall is in flight (or just finished/failed,
            // until the manager clears it) we show the inline HUD here IN PLACE
            // of the brew-install command box, so the bar sits high in the card
            // near the controls instead of pinned to the window bottom.
            if let progress = appData.installProgress[cask.token] {
                InstallHUD(
                    appName: cask.displayName,
                    progress: progress,
                    inline: true
                )
            } else {
                Text("brew install --cask \(cask.token)")
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var installButton: some View {
        let isInstalledAndNotOutdated = viewModel.isInstalled && !viewModel.isOutdated
        let title = viewModel.isInstalled ? (viewModel.isOutdated ? "Update" : "Installed") : "Install"
        let icon = viewModel.isInstalled ? (viewModel.isOutdated ? "arrow.up.circle" : "checkmark.circle") : "arrow.down.circle"
        // Distinct, clearly-active colors per state:
        //   Install → blue   Update → amber   Installed (tap to remove) → green
        //   (shared ActionColors palette — desaturated so hover states are easy
        //    on the eyes instead of fluorescent.)
        let tint: Color = viewModel.isInstalled
            ? (viewModel.isOutdated ? ActionColors.update : ActionColors.installed)
            : ActionColors.install
        // Busy state comes from the shared manager (keyed by this cask's token),
        // not view-local state — so the button stays disabled even if the user
        // navigates away and back while the operation is still running.
        let isBusy = appData.isOperationInFlight(token: cask.token)
        let action: @MainActor () -> Void = {
            // This is a single-function status/action button:
            //   • Install  (not installed)        → start the install
            //   • Update   (installed & outdated)  → start the upgrade
            //   • Installed (installed & current)  → DO NOTHING. It's a status
            //     indicator, not an uninstall trigger. Removal is the dedicated
            //     Uninstall button to the right. (Previously this branch called
            //     startUninstall, so tapping the green "Installed" pill silently
            //     uninstalled the app — a surprising, destructive misfire.)
            if viewModel.isInstalled {
                if viewModel.isOutdated {
                    viewModel.startInstall(appData: appData)   // upgrade path
                }
                // installed & current → no-op
            } else {
                viewModel.startInstall(appData: appData)
            }
        }

        DetailActionButton(
            title: title,
            systemImage: icon,
            tint: tint,
            isProminent: !isInstalledAndNotOutdated
        ) {
            action()
        }
        // Installed-and-current is a status, not an action: disable it so it
        // reads (and behaves) as a non-interactive badge. Install/Update stay
        // live. Busy disables all states while an operation is in flight.
        .disabled(isBusy || isInstalledAndNotOutdated)
        .opacity(isBusy ? 0.6 : 1.0)
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        // Five compact stat cards in a single uniform row. Size leads because
        // it's the new, most-requested fact; the four originals follow. For an
        // installed app Size shows the real on-disk footprint; for a not-yet-
        // installed app it shows the network-probed download size, labeled
        // "Download" so the distinction is explicit. "—" when unknown.
        HStack(spacing: 12) {
            StatCard(label: sizeStatLabel, value: sizeStatValue, icon: "internaldrive")
            // Kind: casks are GUI apps, so the user is clear
            // whether they're looking at an App or a command-line tool.
            StatCard(label: "Kind", value: "App", icon: "app.dashed")
            StatCard(label: "Version", value: cask.version ?? "—", icon: "tag")
            // Last Updated: brew records when this cask was last installed/
            // upgraded on THIS Mac. Honest "—" when not installed (Homebrew's
            // catalog has no canonical per-cask publish date). Auto-Updates
            // moved down into the details sidebar to make room for this card.
            StatCard(label: "Last Catalog Update", value: lastUpdatedDisplay, icon: "calendar")
            // Status: the most important health signal at a glance — whether
            // Homebrew still recommends this cask. "Deprecated" (amber) means
            // it's unmaintained / superseded / slated for removal; "Active"
            // (green) means it's in good standing.
            StatCard(label: "Status",
                     value: cask.deprecated ? "Deprecated" : "Active",
                     icon: cask.deprecated ? "exclamationmark.triangle" : "checkmark.seal")
        }
    }

    // Size card label: "Size" for an installed app's real on-disk footprint,
    // "Download" when we're showing the network-probed artifact size for an
    // app that isn't installed yet.
    private var sizeStatLabel: String {
        if appData.installedByToken[cask.token]?.sizeDisplay != nil { return "Size" }
        return viewModel.sizeIsDownload ? "Download Size" : "Size"
    }

    // Size card value: prefer the installed on-disk size; else the fetched
    // download size; else an em dash while unknown / fetching.
    private var sizeStatValue: String {
        if let onDisk = appData.installedByToken[cask.token]?.sizeDisplay {
            return onDisk
        }
        return viewModel.downloadSizeDisplay ?? "—"
    }

    // "Last Updated" value shown on the detail card. Prefers the REAL catalog
    // date — when this cask's .rb file was last committed in Homebrew/homebrew-
    // cask — which we resolve lazily from GitHub on open (viewModel.catalog
    // LastUpdated). Homebrew's JSON API doesn't expose that date, so until it
    // resolves (or if GitHub is unavailable) we fall back to brew's local
    // install/upgrade date for installed casks, then "—". Never fabricated.
    private var lastUpdatedDisplay: String {
        if let catalog = viewModel.catalogLastUpdated {
            return catalog.formatted(date: .abbreviated, time: .omitted)
        }
        if let date = appData.installedByToken[cask.token]?.installedDate {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return "—"
    }


    // MARK: - Tabbed Content

    // Light, eye-catching color for the "select a tab" hint. Deliberately a
    // fixed soft blue rather than Color.accentColor, so it stays clearly visible
    // (not black/white) regardless of the user's system accent setting.
    private var hintColor: Color { Color(red: 0.30, green: 0.62, blue: 0.96) }

    // The tab picker (hint + segmented control). Lives in the FIXED header so
    // the user can switch tabs without scrolling back up; only the tab body
    // below it scrolls.
    private var tabPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Segmented pickers don't render their title label visibly, so we
            // add an explicit hint above the control telling the user the tabs
            // are selectable for more information.
            VStack(alignment: .leading, spacing: 6) {
                // Directional hint above the segmented control. Uses an
                // explicit light color (not the system accent, which renders as
                // black/white when the user's accent is set to graphite) and a
                // gently animated chevron that nudges right on a loop to draw the
                // eye toward the tabs the user should select.
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    // 0...1 eased sweep on a ~1.4s loop for the chevron nudge.
                    let period = 1.4
                    let raw = (t.truncatingRemainder(dividingBy: period)) / period
                    // Ease in-out so the chevron glides rather than ticks.
                    let eased = 0.5 - 0.5 * cos(raw * 2 * Double.pi)
                    let nudge = CGFloat(eased) * 5   // px of rightward travel

                    HStack(spacing: 5) {
                        Text("Select a tab for more information")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .offset(x: nudge)
                            .opacity(0.6 + 0.4 * eased)
                    }
                    .foregroundStyle(hintColor)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Select a tab to the right for more information")
                Picker("Select Tab", selection: $viewModel.selectedTab) {
                    ForEach(viewModel.visibleTabs, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                // If the selected tab is no longer visible (e.g. About hidden
                // once we learn there's no extra detail), fall back to Overview.
                .onChange(of: viewModel.visibleTabs) { _, tabs in
                    if !tabs.contains(viewModel.selectedTab) {
                        viewModel.selectedTab = .overview
                    }
                }
            }
        }
    }

    // The body of the currently-selected tab. This is the SCROLLABLE region;
    // the fixed header (incl. tabPicker) sits above it.
    @ViewBuilder private var tabBody: some View {
            switch viewModel.selectedTab {
            case .overview:
                ReadmeView(text: viewModel.overviewText, fallback: cask.desc, isLoading: viewModel.overviewResolving, isUpgrading: viewModel.overviewUpgrading)
                    // Opening the tab kicks the lazy resolve of the Overview's
                    // preferred sources (Wikipedia blurb, then project-wiki),
                    // so the "Loading…" note shows while they resolve. Guards
                    // inside ensureOverviewLoaded prevent re-fetching on every
                    // tab switch.
                    .task(id: cask.token) {
                        await viewModel.ensureOverviewLoaded(api: appData.api)
                    }
            case .screenshots:
                ScreenshotsView(urls: viewModel.screenshotURLs, aboutText: viewModel.aboutText, isHomepagePreview: viewModel.screenshotsAreHomepagePreview, isLoading: viewModel.screenshotsLoading)
                    // If the user opens this tab and we have no screenshots and
                    // nothing is in flight, kick a lazy (re)resolve so the
                    // "Loading…" note shows instead of a bare empty state.
                    .task(id: cask.token) {
                        await viewModel.ensureScreenshotsLoaded(api: appData.api)
                    }
            case .dependencies:
                DependenciesView(caskDeps: cask.dependsOn?.cask)
            case .about:
                AboutView(
                    cask: cask,
                    markdown: viewModel.aboutLongForm,
                    repoURL: viewModel.resolvedRepoURL,
                    license: LicenseFormatting.friendlyType(for: viewModel.githubLicense) ?? viewModel.cask.licenseBadgeText,
                    isLoading: viewModel.aboutResolving,
                    webBlurb: viewModel.aboutPanelBlurb,
                    webBlurbLoading: viewModel.aboutWebBlurbLoading,
                    markdownSourceName: {
                        switch viewModel.aboutLongFormSource {
                        case .readme: return "README on GitHub"
                        case .homepage: return "project homepage"
                        case .wikipedia: return "full article on Wikipedia"
                        case .projectWiki: return "project wiki"
                        }
                    }(),
                    markdownSourceURL: {
                        switch viewModel.aboutLongFormSource {
                        case .readme: return viewModel.resolvedRepoURL
                        case .homepage: return cask.homepage.flatMap(URL.init(string:))
                        case .wikipedia: return DetailViewModel.wikipediaArticleURL(for: cask.displayName)
                        case .projectWiki: return viewModel.resolvedRepoURL
                        }
                    }(),
                    isReadme: viewModel.aboutLongFormIsReadme,
                    blurbIsWikipedia: viewModel.aboutPanelBlurbIsWikipedia
                )
                // Opening the tab kicks the lazy resolve: fetch the README if a
                // repo is known, then fall back to a Wikipedia blurb when there
                // is no README to show. Guards inside ensureAboutLoaded keep
                // this from re-fetching on every tab switch.
                .task(id: cask.token) {
                    await viewModel.ensureAboutLoaded(api: appData.api)
                }
            }
    }

    // MARK: - Info Sidebar

    private var infoSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoRow(label: "Homepage", value: cask.homepage ?? "—", isLink: true)
            infoRow(label: "Version", value: cask.version ?? "—")
            // Size now lives in the stat grid at the top of the detail card
            // (on-disk when installed, download size otherwise), so it's no
            // longer duplicated here in the sidebar.
            infoRow(label: "Identifier", value: cask.token, monospaced: true)
            infoRow(label: "Category", value: cask.category.displayName)
            // License moved here from the stat grid so the grid could show the
            // Status (Active/Deprecated) card instead. Same value logic: the
            // resolved SPDX id when known, else the cask's honest badge text,
            // else "Unknown".
            infoRow(label: "License",
                    value: LicenseFormatting.friendlyType(for: viewModel.githubLicense) ?? viewModel.cask.licenseBadgeText ?? "Unknown")
            // Last Updated: brew records when each installed cask was last
            // installed/upgraded on THIS Mac. We surface that as the honest
            // "last updated" signal (Homebrew's catalog API does not expose a
            // canonical per-cask publish date, so we don't invent one). Shown
            // only when the cask is installed and brew gave us a timestamp.
            infoRow(label: "Last Catalog Update", value: lastUpdatedDisplay)
            // Auto-Updates moved here from the stat grid so the grid could show
            // the Last Updated card instead. Whether the app updates itself
            // (Sparkle/built-in) rather than relying on `brew upgrade`.
            infoRow(label: "Auto-Updates", value: cask.autoUpdates == true ? "Yes" : "No")
            Divider()
            noteSection
            Divider()
            TagSection(token: cask.token, type: .cask)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - My Note

    private var noteSection: some View {
        @Bindable var vm = viewModel
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("My Note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.noteJustSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            TextEditor(text: $vm.note)
                .font(.system(size: 12))
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
            HStack(spacing: 8) {
                Spacer()
                if !viewModel.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Remove Note", role: .destructive) {
                        Task {
                            // Clearing the text and saving deletes the note row.
                            viewModel.note = ""
                            await viewModel.saveNote(db: appData.db)
                            await appData.loadNotesAndTagsCount()
                        }
                    }
                    .buttonStyle(OutlinedButtonStyle())
                    .controlSize(.small)
                    .help("Delete this note")
                }
                Button("Save Note") {
                    Task {
                        await viewModel.saveNote(db: appData.db)
                        await appData.loadNotesAndTagsCount()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.noteJustSaved)
    }

    @ViewBuilder
    private func infoRow(label: String, value: String, isLink: Bool = false, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Label: small, uppercased, letter-spaced — a refined section label
            // rather than a raw field name, matching the app's heading style.
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            // Value: clean system text (not the old terminal-style monospace).
            // Identifiers/tokens opt into monospace via `monospaced: true` so
            // they still read as code, but at a tighter, on-theme size.
            if isLink, let url = URL(string: value), url.scheme?.hasPrefix("http") == true {
                Link(destination: url) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .opacity(0.7)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else if monospaced {
                Text(value)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
    }
}
