import SwiftUI

struct FavoriteButton: View {
    let token: String
    // When true (and the app is not yet a favorite), show a small inline
    // "Add to favorites" hint beside the star so it's obvious the star is
    // clickable. Cards pass their hover state here; default false keeps the
    // bare star everywhere else (e.g. the detail header).
    var showHint: Bool = false
    // When true, the hint text is placed AFTER (to the right of) the star
    // instead of before it. The detail header sits the star right next to the
    // app title, so a leading hint crowds the title — a trailing hint grows
    // into the empty space toward the trailing Spacer instead. Cards keep the
    // default (leading) hint since their star sits at the row trailing edge.
    var hintTrailing: Bool = false
    @Environment(AppDataService.self) var appData

    private var isFav: Bool {
        appData.isFavorite(token)
    }

    private var hint: some View {
        Text("Add to favorites")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            .transition(.opacity)
    }

    private var showVisibleHint: Bool { showHint && !isFav }

    private var star: some View {
        Image(systemName: isFav ? "star.fill" : "star")
            .foregroundStyle(isFav ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            .font(.system(size: 14))
    }

    var body: some View {
        Button {
            Task {
                await appData.toggleFavorite(token: token)
            }
        } label: {
            // Two different strategies so the star NEVER moves on hover:
            //
            // • Cards (default): the hint is a real layout member to the LEFT of
            //   the star. The star is pinned at the card's trailing edge by a
            //   leading Spacer, so growing the hint to its left doesn't move it.
            //
            // • Detail header (hintTrailing): the button is scaled (1.3x) and
            //   scaling happens around the button's CENTER, so if the button
            //   grew wider when the hint appeared, the star would drift. To keep
            //   the button's width — and therefore its scale center — perfectly
            //   constant, the hint here is a ZERO-FOOTPRINT overlay pinned just
            //   past the star's trailing edge (so it can't overlap the title).
            if hintTrailing {
                // Zero-footprint overlay so the button's width (and its 1.3x
                // scale center) never changes on hover and the star stays put.
                // Pin the hint's leading edge to the star's leading edge, then
                // push it right past the star glyph (~13pt at 14pt font) so it
                // sits cleanly to the RIGHT — never over the title on the left.
                star
                    .overlay(alignment: .leading) {
                        if showVisibleHint {
                            hint
                                .fixedSize()
                                .offset(x: 20)
                        }
                    }
            } else {
                HStack(spacing: 6) {
                    if showVisibleHint { hint }
                    star
                }
            }
        }
        .buttonStyle(.plain)
        .help(isFav ? "Remove from Favorites" : "Click to add to Favorites")
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: showHint)
    }
}

struct FavoritesView: View {
    @Environment(AppDataService.self) var appData
    @State private var favorites: [CaskMetadata] = []
    @State private var isLoading = false
    // Called when a card is tapped; the parent presents the detail page.
    var onCaskTapped: ((CaskMetadata) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    PageTitleLabel(title: "Favorites")
                    Text("\(favorites.count) saved")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if favorites.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "star")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text("No favorites yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Tap the star on any app to save it here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                        ForEach(favorites) { cask in
                            // AppCardView already shows its own favorite star,
                            // so no overlay is needed here.
                            AppCardView(
                                cask: cask,
                                installed: appData.installedByToken[cask.token],
                                installCount: cask.installCount30d,
                                onTap: { onCaskTapped?($0) },
                                onInstall: { c in
                                    Task {
                                        for await _ in appData.install(cask: c.token) {}
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .padding(20)
        }
        .task {
            await reload()
        }
        .onChange(of: appData.favoriteTokens) { _, _ in
            Task {
                await reload()
            }
        }
    }

    private func reload() async {
        isLoading = true
        favorites = await appData.fetchFavoriteCasks()
        isLoading = false
    }
}
