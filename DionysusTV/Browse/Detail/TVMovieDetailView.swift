import SwiftUI

/// A movie's page (prototype screen 7): the header and actions fill the
/// first screen over the backdrop; Cast & Crew, More Like This and Details
/// scroll up from below.
struct TVMovieDetailView: View {
    let viewModel: AssetDetailViewModel
    let item: MediaItem
    let client: JellyfinAPIClient
    let userID: String
    @Binding var rememberedFocus: String?
    /// True once focus has moved below the header and actions: the page
    /// blurs its backdrop so the rails read against it.
    @Binding var isBelowHeader: Bool
    @Environment(\.tvOpenRoute) private var open
    @FocusState private var focus: String?
    @State private var showsFullOverview = false

    private var focusIDs: [String] {
        TVDetailActions.focusIDs(playTarget: item)
            + (item.hasDescription ? [TVDetailFocus.overview] : [])
            + item.cast.map { "cast.\($0.id)" }
            + viewModel.similar.map { "similar.\($0.id)" }
            + (TVDetailsPanel.hasRows(for: item) ? [TVDetailsPanel.focusID] : [])
    }

    private var isLoading: Bool { viewModel.loadState != .loaded }

    /// Whether a focus id sits below the header and actions.
    private static func isBelowHeader(_ id: String) -> Bool {
        id.hasPrefix("cast.") || id.hasPrefix("similar.") || id == TVDetailsPanel.focusID
    }

    var body: some View {
        scrollView
            .tvDetailLanding(focus: focus, isBelowHeader: $isBelowHeader, isBelow: Self.isBelowHeader)
        .scrollClipDisabled()
        .tvClaimsFocus($focus, ids: focusIDs, remembered: $rememberedFocus)
        .fullScreenCover(isPresented: $showsFullOverview) {
            TVFullOverview(title: item.name, overview: item.overview ?? "")
        }
    }

    private var scrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                VStack(alignment: .leading, spacing: 22) {
                    // The page opens on the tile's lighter copy of the item
                    // and the full one arrives a moment (or, from a cold
                    // server, seconds) later with its badges, credits and
                    // sometimes its overview. Each keeps its space meanwhile,
                    // and the text rows always take their full line count, so
                    // nothing above them jumps when it lands.
                    TVDetailHeader(item: item, isLoading: isLoading)
                    if item.hasDescription || isLoading {
                        Button { showsFullOverview = true } label: {
                            Text(verbatim: item.overview ?? " ")
                                .lineLimit(3, reservesSpace: true)
                                .multilineTextAlignment(.leading)
                                .frame(width: 900, alignment: .leading)
                        }
                        // Plain, not the system button (Benjamin, 2026-10-02):
                        // that draws a background at rest, too heavy for text.
                        .buttonStyle(.plain)
                        .disabled(!item.hasDescription)
                        .focused($focus, equals: TVDetailFocus.overview)
                        .accessibilityIdentifier(A11yID.TV.Detail.overview)
                    }
                    if creditsLine != nil || isLoading {
                        Text(verbatim: creditsLine ?? " ")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2, reservesSpace: true)
                            .frame(width: 900, alignment: .leading)
                    }
                    TVDetailActions(viewModel: viewModel, playTarget: item, statusTarget: item, isShow: false, focus: $focus, play: play)
                        .padding(.top, 16)
                }
                // The first screen: Cast & Crew peeks at its foot.
                .tvDetailHeaderFrame(art: item)

                if !item.cast.isEmpty {
                    TVCastRail(cast: item.cast, focus: $focus)
                }
                if !viewModel.similar.isEmpty {
                    TVRail(title: String(localized: "More Like This")) {
                        let shape = TVTileShape(items: viewModel.similar)
                        ForEach(viewModel.similar) { similar in
                            TVShapedTile(item: similar, shape: shape, identifier: A11yID.TV.Detail.similar(similar.id)) {
                                open(.assetDetail(itemID: similar.id, preloadedItem: similar))
                            }
                            .focused($focus, equals: "similar.\(similar.id)")
                        }
                    }
                }
                TVDetailsPanel(item: item, focus: $focus)
            }
            .padding(.top, 60)
            .padding(.bottom, 160)
        }
    }

    private func play(_ request: PlaybackRequest) {
        TVPlayerPresenter.present(request, client: client, userID: userID) { outcome in
            viewModel.applyOptimisticPlaybackPosition(outcome)
            Task { await viewModel.refreshItem() }
        }
    }

    /// "Starring A, B, C · Directed by D", from the item's people.
    private var creditsLine: String? {
        let people = item.dto.people ?? []
        let actors = people.filter { $0.type == "Actor" }.prefix(3).map(\.name)
        let director = people.first { $0.type == "Director" }?.name
        let parts = [
            actors.isEmpty ? nil : String(localized: "Starring \(actors.joined(separator: ", "))"),
            director.map { String(localized: "Directed by \($0)") }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The whole overview, for one too long for three lines. Menu closes it.
struct TVFullOverview: View {
    let title: String
    let overview: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text(verbatim: title).font(.title2.bold())
            ScrollView { Text(verbatim: overview).frame(maxWidth: .infinity, alignment: .leading) }
            Button("Close") { dismiss() }.focused($closeFocused)
        }
        .padding(120)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($closeFocused, true)
    }
}
