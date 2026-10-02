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
    @State private var showsFullDetails = false

    private var focusIDs: [String] {
        TVDetailActions.focusIDs(playTarget: item)
            + (item.hasDescription ? [TVDetailFocus.overview] : [])
            + item.cast.map { "cast.\($0.id)" }
            + viewModel.similar.map { "similar.\($0.id)" }
            + (hasDetails ? [Self.detailsFocus] : [])
    }

    private static let detailsFocus = "details"
    private var isLoading: Bool { viewModel.loadState != .loaded }
    private static let headerHeight: CGFloat = 776
    private var hasDetails: Bool { !detailRows.isEmpty }

    /// Whether a focus id sits below the header and actions.
    private static func isBelowHeader(_ id: String) -> Bool {
        id.hasPrefix("cast.") || id.hasPrefix("similar.") || id == detailsFocus
    }

    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// From the inset top, which is where `scrollTo(edge: .top)` goes: zero
    /// at the page's start position.
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        scrollView
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                scrollOffset = offset
            }
            .onChange(of: focus) { _, new in
                guard let new else { return }
                let below = Self.isBelowHeader(new)
                isBelowHeader = below
                if !below { restoreLanding() }
            }
            // In the header (the synopsis or the actions) the page sits at
            // its start position: back from the rails it returns there, and
            // focusing the synopsis doesn't scroll it higher. tvOS by itself
            // scrolls only far enough to show the focused control, and its
            // scroll can start after ours and win (seen from one row down,
            // and again from three), so the page is also sent back whenever a
            // scroll comes to rest anywhere else while focus is up here.
            .onScrollPhaseChange { _, phase in
                if phase == .idle, !isBelowHeader { restoreLanding() }
            }
        .scrollClipDisabled()
        .tvClaimsFocus($focus, ids: focusIDs, remembered: $rememberedFocus)
        .fullScreenCover(isPresented: $showsFullOverview) {
            TVFullOverview(title: item.name, overview: item.overview ?? "")
        }
        .fullScreenCover(isPresented: $showsFullDetails) {
            TVFullDetailsView(item: item)
        }
    }

    private func restoreLanding() {
        guard abs(scrollOffset) > 1 else { return }
        withAnimation(.easeInOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .top) }
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
                // The first screen: Cast & Crew peeks at its foot. At this
                // height Play sits where tvOS wants a focused control, so the
                // page opens at its true top; 60pt taller and tvOS nudged the
                // page down on landing, which made "the start position"
                // something to measure rather than the top (`restoreLanding`).
                .frame(minHeight: Self.headerHeight, alignment: .bottomLeading)

                if !item.cast.isEmpty {
                    castRail
                }
                if !viewModel.similar.isEmpty {
                    TVRail(title: String(localized: "More Like This")) {
                        ForEach(viewModel.similar) { similar in
                            TVPosterTile(item: similar, caption: .always, identifier: A11yID.TV.Detail.similar(similar.id)) {
                                open(.assetDetail(itemID: similar.id, preloadedItem: similar))
                            }
                            .focused($focus, equals: "similar.\(similar.id)")
                        }
                    }
                }
                if hasDetails {
                    detailsBlock
                }
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

    /// Focusable and walkable, though Select does nothing yet: there is no
    /// person page (Benjamin, 2026-10-02).
    private var castRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast & Crew").font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 56) {
                    ForEach(item.cast) { member in
                        Button {} label: {
                            VStack(spacing: 14) {
                                AsyncRemoteImage(url: member.imageURL, placeholderSystemImage: "person.fill")
                                    .frame(width: 180, height: 180)
                                    .clipShape(Circle())
                                    .accessibilityHidden(true)
                                Text(verbatim: member.name).font(.caption.weight(.semibold)).lineLimit(1)
                                if let role = member.role {
                                    Text(verbatim: role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: 180)
                        }
                        .buttonStyle(TVCastTileStyle())
                        .focused($focus, equals: "cast.\(member.id)")
                        .accessibilityElement(children: .combine)
                        .accessibilityRemoveTraits(.isButton)
                        .accessibilityIdentifier(A11yID.TV.Detail.cast(member.id))
                    }
                }
                .padding(.vertical, 30)
                .padding(.trailing, 80)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    /// What the item has to say about itself; the technical rows are there
    /// only once the full item, with its media source, has loaded.
    private var detailRows: [(label: String, value: String)] {
        let details = item.technicalDetails
        let video = [details?.resolution, details?.dynamicRange].compactMap { $0 }.joined(separator: " · ")
        let rows: [(String, String?)] = [
            (String(localized: "Studio"), item.studios.first),
            (String(localized: "Released"), item.metadataDateText),
            (String(localized: "Genres"), item.genres.isEmpty ? nil : item.genres.joined(separator: ", ")),
            (String(localized: "Rating"), item.ageRating),
            (String(localized: "Video"), video),
            (String(localized: "Audio"), details?.audioTracks.first),
            (String(localized: "Subtitles"), (details?.subtitleTracks.isEmpty ?? true) ? nil : details?.subtitleTracks.joined(separator: ", ")),
            (String(localized: "Runtime"), item.durationText)
        ]
        return rows.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }

    private var detailsBlock: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Details").font(.headline).accessibilityAddTraits(.isHeader)
            // A summary; Select opens the full list (`TVFullDetailsView`).
            Button { showsFullDetails = true } label: {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 4), alignment: .leading, spacing: 30) {
                    ForEach(detailRows, id: \.label) { label, value in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: label.uppercased()).font(.caption2).foregroundStyle(.secondary)
                            Text(verbatim: value).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                }
                .padding(30)
                .background(.white.opacity(focus == Self.detailsFocus ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 24))
            }
            .buttonStyle(.plain)
            .focused($focus, equals: Self.detailsFocus)
            .accessibilityLabel(String(localized: "Details"))
            .accessibilityHint(String(localized: "Shows every detail and track"))
            .accessibilityIdentifier(A11yID.TV.Detail.details)
        }
        .padding(.trailing, 80)
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

/// A person in Cast & Crew: the portrait lifts and gains a ring on focus.
private struct TVCastTileStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.12 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 20, y: 12)
            .opacity(isFocused ? 1 : 0.85)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
