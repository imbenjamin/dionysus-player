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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // `LazyHStack`, not `HStack` — see `MediaRailView`'s identical
            // change for why (defers construction/image loading to
            // on-screen items only). Libraries are typically few enough
            // that this matters less here, but there's no reason for this
            // rail to be the odd one out.
            LazyHStack(spacing: 12) {
                ForEach(libraries) { library in
                    LibraryCard(library: library)
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct LibraryCard: View {
    let library: MediaItem
    private let width: CGFloat = 160

    var body: some View {
        NavigationLink(value: AppRoute.collection(query)) {
            AsyncRemoteImage(url: library.imageURL(type: "Primary", maxWidth: 400), contentMode: .fill)
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var query: CollectionQuery {
        CollectionQuery(title: library.name, parentID: library.id)
    }
}

#Preview {
    LibraryRailView(libraries: [])
}
