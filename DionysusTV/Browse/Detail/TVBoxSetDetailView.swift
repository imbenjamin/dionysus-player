import SwiftUI

/// A box set: its name and overview, then its movies as a poster grid. Each
/// opens its own detail page; the set itself has nothing to play.
struct TVBoxSetDetailView: View {
    let viewModel: AssetDetailViewModel
    let item: MediaItem
    @Binding var rememberedFocus: String?
    @Binding var isBelowHeader: Bool
    @Environment(\.tvOpenRoute) private var open
    @FocusState private var focus: String?
    /// Bumped by Menu once scrolled: the page goes back to its top.
    @State private var topRequest = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 40) {
                    TVDetailHeader(item: item, showsBadges: false)
                    if let overview = item.overview, item.hasDescription {
                        Text(verbatim: overview).lineLimit(3).frame(width: 900, alignment: .leading).foregroundStyle(.white.opacity(0.82))
                    }
                }
                .tvDetailHeaderFrameWhenNoBackdrop(art: item)
                if viewModel.collectionItems.isEmpty {
                    if viewModel.loadState == .loaded {
                        TVDetailEmptyMessage(text: String(localized: "This collection is empty."))
                    } else {
                        TVDetailLoading()
                    }
                } else {
                    let shape = TVTileShape(items: viewModel.collectionItems)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: shape.railSize.width, maximum: shape.railSize.width), spacing: 48, alignment: .topLeading)], alignment: .leading, spacing: 60) {
                        ForEach(viewModel.collectionItems) { member in
                            TVShapedTile(item: member, shape: shape, identifier: A11yID.TV.Detail.member(member.id)) {
                                open(.assetDetail(itemID: member.id, preloadedItem: member))
                            }
                            .focused($focus, equals: member.id)
                        }
                    }
                    .focusSection()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 60)
            .padding(.bottom, 160)
            .padding(.trailing, 80)
        }
        .tvDetailDimsWhenScrolled($isBelowHeader)
        .tvScrollsToTop(on: topRequest)
        .scrollClipDisabled()
        .tvClaimsFocus($focus, ids: viewModel.collectionItems.map(\.id), remembered: $rememberedFocus)
        .tvMenuReturnsToLanding($focus, landing: viewModel.collectionItems.first?.id, isAway: isBelowHeader) { topRequest += 1 }
    }
}

/// Shown in place of an empty box set's or playlist's items. It takes focus,
/// so the page has somewhere for focus to be and Menu still pops: with focus
/// nowhere, tvOS delivers Menu to nothing.
struct TVDetailEmptyMessage: View {
    let text: String
    @FocusState private var focused: String?
    @State private var remembered: String?

    var body: some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 30).padding(.vertical, 16)
            .background(.white.opacity(focused == nil ? 0 : 0.1), in: Capsule())
            .focusable()
            .focused($focused, equals: "empty")
            .accessibilityIdentifier(A11yID.TV.Detail.emptyMessage)
            .tvClaimsFocus($focused, ids: ["empty"], remembered: $remembered)
    }
}

/// Shown while a page's content is still on its way: a detail page, a box
/// set, a playlist, a library and Home. It takes focus for the same reason
/// as `TVDetailEmptyMessage`, and because the shell, finding focus nowhere
/// three seconds after a push or a choice from the sidebar, opens the
/// sidebar over the page, where Menu then leaves the app instead of popping
/// or returning to the page (M3 review; Home and a library seen on a slow
/// server, Benjamin, 2026-10-05). The page's own claim takes focus from it
/// once the content lands.
struct TVDetailLoading: View {
    @FocusState private var focused: String?
    @State private var remembered: String?

    var body: some View {
        ProgressView()
            .padding(24)
            .focusable()
            .focused($focused, equals: "loading")
            .accessibilityLabel(Text("Loading"))
            .accessibilityIdentifier(A11yID.TV.Detail.loading)
            .tvClaimsFocus($focused, ids: ["loading"], remembered: $remembered)
    }
}

extension View {
    /// For a page that is a grid beneath a short header (a box set, a
    /// playlist): the backdrop blurs once the page has scrolled away from
    /// its top, where the movie page goes by which row has focus.
    func tvDetailDimsWhenScrolled(_ isBelowHeader: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 120 } action: { _, scrolled in
            isBelowHeader.wrappedValue = scrolled
        }
    }
}
