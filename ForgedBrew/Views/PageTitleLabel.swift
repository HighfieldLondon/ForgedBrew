import SwiftUI

// A page title that shows the small ForgedBrew logo to the left of the screen's
// large bold heading. Used across the main screens (Installed, Parked, Updates,
// etc.) so every page title carries the app mark consistently.
//
// The icon is sized relative to the title text and kept deliberately small so
// it reads as a subtle brand mark, not a heavy graphic.
struct PageTitleLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image("ForgedBrewLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text(title)
                .font(.title)
                .fontWeight(.bold)
        }
    }
}