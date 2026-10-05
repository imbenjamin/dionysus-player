import SwiftUI

/// Search (prototype screen 10), on the shared `SearchViewModel`: the system
/// keyboard, results as rails by type (`TVSearchGrouping`), and with the field
/// empty the results most recently opened. Every result opens a detail page.
///
/// The keyboard is the system's (Benjamin, 2026-10-01), laid out full screen
/// as it is designed to be (Benjamin, 2026-10-04): the shell slides the
/// collapsed rail off the left edge here (`TVShellNavigation
/// .hidesCollapsedRail`), and Menu slides the open sidebar back in. Beside
/// the rail the keyboard's first keys and the field's hint ran off the
/// screen, whatever inset its container had: the search chrome is laid out
/// for the window's width. Left stays in the keyboard.
struct TVSearchView: View {
    /// Owned by the shell, so the query and results outlive Search's views,
    /// which are torn down whenever another page is chosen.
    let viewModel: SearchViewModel
    /// The tile that last had focus, kept by the shell, so a rebuilt Search
    /// puts focus back on it.
    @Binding var rememberedResultID: String?
    @FocusState private var focusedResultID: String?
    @Environment(\.tvOpenRoute) private var open
    @Environment(\.tvPageIsOnShow) private var isOnShow
    @State private var restoring = false
    @Environment(\.tvFocusHandoff) private var focusHandoff
    @Environment(\.tvPageClaimedFocus) private var claimedFocus


    private var sections: [TVSearchGrouping.Section] { TVSearchGrouping.sections(viewModel.results) }
    private var isIdle: Bool { viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Focus ids of the tiles on show: a recent search's is prefixed, since
    /// the same title can be both a result and a recent search.
    private var focusIDs: [String] {
        isIdle ? viewModel.history.map { Self.recentFocusID($0.id) } : viewModel.results.map(\.id)
    }

    private static func recentFocusID(_ id: String) -> String { "recent.\(id)" }

    var body: some View {
        @Bindable var viewModel = viewModel
        TVPageScaffold(layout: .fullScreen) {
            // `.searchable` draws its field only inside a navigation container.
            NavigationStack {
                content
                    .searchable(text: $viewModel.query)
            }
        }
        .onChange(of: viewModel.query) { viewModel.queryChanged() }
        .task(id: viewModel.results.count + viewModel.history.count) { await viewModel.loadImagesIfNeeded() }
        // Search's default focus is the system keyboard, a UIKit control no
        // SwiftUI focus target reaches: with the rail held disabled, tvOS puts
        // focus there itself. Only a remembered tile is claimed here.
        .onAppear {
            if let rememberedResultID, focusIDs.contains(rememberedResultID) {
                focusedResultID = rememberedResultID
            }
            releaseRail()
        }
        .onChange(of: focusHandoff) { releaseRail() }
        // Back on show after a detail page is popped: tvOS puts focus on the
        // keyboard as the page is enabled again, so the tile is claimed
        // until it holds (as `tvClaimsFocus` does for other pages).
        .onChange(of: isOnShow) { _, onShow in
            guard onShow, let target = rememberedResultID, focusIDs.contains(target) else { return }
            restoring = true
            Task { @MainActor in
                for _ in 0..<10 {
                    focusedResultID = target
                    try? await Task.sleep(for: .milliseconds(50))
                    if focusedResultID == target { break }
                }
                restoring = false
                claimedFocus()
            }
        }
        .onChange(of: focusedResultID) { _, id in
            if let id, isOnShow, !restoring { rememberedResultID = id }
        }
    }

    /// Lets the shell enable the rail once the keyboard has had its chance at
    /// focus, which it takes as soon as the page is laid out.
    private func releaseRail() {
        guard isOnShow else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            claimedFocus()
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                if isIdle {
                    recentSearches
                } else if case .failed(let message) = viewModel.loadState {
                    notice(Text(verbatim: message))
                } else if sections.isEmpty, viewModel.loadState == .loaded {
                    notice(Text("No results for “\(viewModel.query)”"))
                        .accessibilityIdentifier(A11yID.TV.Search.noResults)
                } else {
                    ForEach(sections) { section in
                        TVRail(title: section.title, titleIdentifier: A11yID.TV.Search.section(section.id)) {
                            ForEach(section.results) { result in
                                tile(result, shape: TVTileShape(results: section.results), focusID: result.id, identifier: A11yID.TV.Search.result(result.id))
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
    }

    private func notice(_ text: Text) -> some View {
        text
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
    }

    /// The results last opened, grouped by type as results are (Benjamin,
    /// 2026-10-04), under one heading with Clear beside it. The heading row is
    /// a focus section, so Up from anywhere in the rails reaches Clear. With
    /// none yet, iOS's placeholder, in its words.
    @ViewBuilder
    private var recentSearches: some View {
        if viewModel.history.isEmpty {
            ContentUnavailableView(
                "Search Your Library",
                systemImage: "magnifyingglass",
                description: Text("Find movies, shows, and episodes on your server.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .accessibilityIdentifier(A11yID.TV.Search.emptyHistory)
        } else {
            HStack(spacing: 32) {
                Text("Recent Searches")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Button("Clear") { viewModel.clearHistory() }
                    .accessibilityIdentifier(A11yID.TV.Search.clearRecent)
                Spacer(minLength: 0)
            }
            .focusSection()
            // Keyed apart from the results' rails: sharing their ids
            // ("movies"), the lazy stack kept the results' rail in place when
            // the field was emptied.
            ForEach(TVSearchGrouping.sections(viewModel.history), id: \.recentKey) { section in
                TVRail(title: section.title, titleIdentifier: A11yID.TV.Search.recentSection(section.id)) {
                    ForEach(section.results) { result in
                        tile(result, shape: TVTileShape(results: section.results), focusID: Self.recentFocusID(result.id), identifier: A11yID.TV.Search.recent(result.id))
                    }
                }
            }
        }
    }

    /// Search hints carry no watched or favourite state, so these tiles have
    /// no badges; the detail page shows both.
    /// In its rail's shape (`TVTileShape`): a poster, or for shows and
    /// episodes a landscape thumb, which the hint names by the episode's own
    /// still or its show's thumb.
    private func tile(_ result: SearchResult, shape: TVTileShape, focusID: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                viewModel.recordSelection(result)
                open(.assetDetail(itemID: result.id))
            } label: {
                AsyncRemoteImage(
                    url: viewModel.imageURL(for: result, preferLandscape: shape == .landscape, maxWidth: shape == .landscape ? 1000 : 500),
                    placeholderSystemImage: result.kind?.placeholderSystemImage ?? "film"
                )
                .frame(width: shape.railSize.width, height: shape.railSize.height)
            }
            .buttonStyle(.card)
            .focused($focusedResultID, equals: focusID)
            .accessibilityLabel(result.accessibilityDescription)
            .accessibilityIdentifier(identifier)

            TVTileCaptionText(
                title: result.name,
                subtitle: result.subtitle,
                artSize: shape.railSize,
                isFocused: focusedResultID == focusID
            )
        }
    }
}

private extension TVSearchGrouping.Section {
    var recentKey: String { "recent.\(id)" }
}
