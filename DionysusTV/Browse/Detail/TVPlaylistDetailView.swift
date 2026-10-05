import SwiftUI

/// A playlist, read-only in M3: Play or Resume, then its items in order. A
/// row plays that item with the playlist as the queue, as iOS's rows do; it
/// doesn't open a detail page.
struct TVPlaylistDetailView: View {
    let viewModel: AssetDetailViewModel
    let item: MediaItem
    let client: JellyfinAPIClient
    let userID: String
    @Binding var rememberedFocus: String?
    @Binding var isBelowHeader: Bool
    @FocusState private var focus: String?

    private var items: [MediaItem] { viewModel.orderedPlaylistItems }

    /// Keyed on the playlist entry, not the item: the same item can be in a
    /// playlist twice.
    private static func key(_ member: MediaItem) -> String { "member.\(member.playlistItemID ?? member.id)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                TVDetailHeader(item: item, showsBadges: false)
                if let overview = item.overview, item.hasDescription {
                    Text(verbatim: overview).lineLimit(3).frame(width: 900, alignment: .leading).foregroundStyle(.white.opacity(0.82))
                }
                if let target = viewModel.playlistResumeTarget {
                    Button { play(target) } label: {
                        Label(TVDetailFormat.playTitle(target: target, isShow: false) ?? String(localized: "Play"), systemImage: "play.fill")
                            .frame(minWidth: 320, alignment: .leading)
                    }
                    .focused($focus, equals: TVDetailFocus.play)
                    .accessibilityIdentifier(A11yID.TV.Detail.play)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                } else if viewModel.loadState == .loaded {
                    TVDetailEmptyMessage(text: String(localized: "This playlist is empty."))
                }
                let shape = TVTileShape(items: items)
                let tileWidth = shape == .landscape ? TVTileMetrics.episode.width : TVTileMetrics.poster.width
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth), spacing: 44, alignment: .topLeading)], alignment: .leading, spacing: 50) {
                    ForEach(items, id: \.playlistItemID) { member in
                        TVShapedTile(
                            item: member, shape: shape, landscapeSize: TVTileMetrics.episode,
                            identifier: A11yID.TV.Detail.member(member.playlistItemID ?? member.id)
                        ) { play(member) }
                        .focused($focus, equals: Self.key(member))
                    }
                }
                .focusSection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 60)
            .padding(.bottom, 160)
            .padding(.trailing, 80)
        }
        .tvDetailDimsWhenScrolled($isBelowHeader)
        .scrollClipDisabled()
        .tvClaimsFocus($focus, ids: (viewModel.playlistResumeTarget == nil ? [] : [TVDetailFocus.play]) + items.map(Self.key), remembered: $rememberedFocus)
    }

    private func play(_ member: MediaItem) {
        TVPlayerPresenter.present(PlaybackRequest(itemID: member.id), queue: items, client: client, userID: userID) { outcome in
            viewModel.applyOptimisticPlaybackPosition(outcome)
            Task { await viewModel.refreshItem() }
        }
    }
}
