import SwiftUI

/// Home's second rail: the user's own libraries (Movies, Shows,
/// Collections, ...), one card per entry from `/Users/{id}/Views` — replaces
/// the old `TopMenuBar` pill row. Each card pushes a `CollectionGridView`
/// scoped to that library rather than an asset detail page, so this can't
/// just reuse `PosterCard` (hardwired to `.assetDetail`) or `MediaRailView`
/// (expects a "See All" query, which a library card has no further "all" to
/// see beyond itself).
///
/// No title row and no per-card label/gradient, unlike the other rails —
/// library images already have their name baked in server-side, so a text
/// overlay would just duplicate it.
struct LibraryRailView: View {
    let libraries: [MediaItem]

    /// Same `.regular`-size-class scale-up as `MediaRailView`'s
    /// `posterWidth`/`landscapeWidth` — see that property's doc comment.
    /// `LibraryCard`'s own default (160) is what `.compact` keeps.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var cardWidth: CGFloat { horizontalSizeClass == .regular ? 200 : 160 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // `LazyHStack`, not `HStack` — see `MediaRailView`'s identical
            // change for why (defers construction/image loading to
            // on-screen items only). Libraries are typically few enough
            // that this matters less here, but there's no reason for this
            // rail to be the odd one out.
            LazyHStack(spacing: 12) {
                ForEach(libraries) { library in
                    LibraryCard(library: library, width: cardWidth)
                }
            }
            .padding(.horizontal)
        }
        .accessibilityIdentifier(A11yID.Home.libraryRail)
    }
}

private struct LibraryCard: View {
    let library: MediaItem
    var width: CGFloat = 160

    var body: some View {
        // Wrapped in a (single-child) `ZStack`, not a bare `NavigationLink`
        // — same bare-NavigationLink-in-a-Lazy-stack freeze fix as
        // `PosterCard.body` (see `library-rail-navigationlink-freeze`
        // memory). This card has the identical shape (`LibraryRailView`'s
        // own `LazyHStack` above) but lives in a different file, so it was
        // never automatically covered by that fix — applied here
        // defensively, ahead of its own confirmed repro.
        ZStack {
            NavigationLink(value: AppRoute.collection(query)) {
                AsyncRemoteImage(
                    url: library.imageURL(type: "Primary", maxWidth: 400),
                    contentMode: .fill,
                    // A library is a browsable shelf of many items —
                    // deliberately distinct from `.boxSet`'s glyph, which
                    // represents one themed grouping instead.
                    placeholderSystemImage: "square.grid.2x2"
                )
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            // No title row on this card at all (see this type's doc
            // comment) — without an explicit label, VoiceOver had nothing
            // to read here whatsoever (confirmed blank/"Unnamed").
            //
            // `.accessibilityElement(children: .ignore)` added alongside —
            // this card only has the one child today, so it was harmless
            // without it, but bringing it in line with the house pattern
            // (`PosterCard`, `HeroRailCard`, `CastMemberCard`) protects
            // against a future second child leaking its own content into
            // VoiceOver's read.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(library.name)
            .accessibilityIdentifier(A11yID.Media.card(library.id))
            .accessibilityAddTraits(.isButton)
        }
    }

    private var query: CollectionQuery {
        CollectionQuery(title: library.name, parentID: library.id, includeItemTypes: library.libraryContentItemTypes)
    }
}

#Preview {
    LibraryRailView(libraries: [])
}
