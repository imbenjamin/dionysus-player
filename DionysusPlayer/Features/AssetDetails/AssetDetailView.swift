import SwiftUI

/// Loads an item and dispatches to the Movie or Show detail layout based on
/// its type.
///
/// `viewModel` is constructed synchronously in `init` rather than lazily via
/// `.task` on an optional `@State`, the pattern every other feature's root view
/// uses. That pattern always has a render pass where the ViewModel is nil and a
/// blank `LoadingView()` shows. Building it eagerly with `preloadedItem` seeded
/// in (see `AppRoute.assetDetail`) makes the first frame render the real hero
/// header.
struct AssetDetailView: View {
    let itemID: String
    @State private var viewModel: AssetDetailViewModel

    /// Bumped once `viewModel.loadIfNeeded()` returns, forcing an identity reset
    /// of `content` so the detail layout re-renders with the fully-loaded
    /// `viewModel.item` — cast, technical details, similar/collections rails —
    /// rather than the shallow `preloadedItem` it first rendered with.
    ///
    /// `viewModel.item` mutating isn't reliably enough for this page to pick it
    /// up: the same class of bug the detail views' own `refreshTrigger` works
    /// around for the post-playback refresh, which nothing covered for the
    /// initial load. Reaching an item from a Home rail card, which seeds a
    /// preload, `MovieDetailView.body` intermittently never re-ran after
    /// `load()` finished even though `viewModel.item` had been replaced with the
    /// full item — leaving the page stuck on preload-level fields with no cast,
    /// Details tab, format badges or rails, and no error since nothing failed.
    /// Search, with no preload, never reproduced it: that path renders `content`
    /// once, already loaded.
    ///
    /// A plain `@State` write is what makes this reliable where re-reading
    /// `viewModel.item`/`loadState` isn't — see `refreshTrigger`. Bumped
    /// unconditionally after `loadIfNeeded()` rather than gated on
    /// `preloadedItem`: a redundant reset costs nothing this early, and
    /// re-deriving "did this session need it" could drift from
    /// `AssetDetailViewModel.load()`'s behavior.
    @State private var loadCompletionTrigger = UUID()

    /// `client`/`userID` are passed in rather than read from
    /// `@Environment(AppState.self)`, so `viewModel` can be built in `init`:
    /// environment values aren't resolved for this view yet at that point, only
    /// for the ancestor constructing it.
    init(itemID: String, preloadedItem: MediaItem? = nil, client: JellyfinAPIClient, userID: String) {
        self.itemID = itemID
        _viewModel = State(initialValue: AssetDetailViewModel(
            client: client, userID: userID, itemID: itemID, preloadedItem: preloadedItem
        ))
    }

    var body: some View {
        content
            .id(loadCompletionTrigger)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await viewModel.loadIfNeeded()
                loadCompletionTrigger = UUID()
            }
            // Stops any in-flight toggle confirmation poll or post-playback
            // refresh once this page leaves the screen — see
            // `AssetDetailViewModel.cancelBackgroundWork()`. Here because this is
            // `viewModel`'s screen-level owner, not a toolbar item or sub-view
            // whose `.onDisappear` is less predictable.
            .onDisappear { viewModel.cancelBackgroundWork() }
            // Something was deleted from the server, possibly by the page that
            // was until a moment ago on top of this one. Popping back to a parent
            // doesn't refresh it (see `DeletedItemBroadcaster`), so without this a
            // show page keeps listing the episode just deleted from it. Guarded on
            // the page having loaded, so this can't refresh a view model that
            // hasn't.
            .onChange(of: DeletedItemBroadcaster.shared.token) {
                // Skip when the deleted thing is what this page shows: it's on
                // its way out (`DeletionOutcome.popOneLevel`), and re-fetching it
                // is a guaranteed 404.
                guard let shown = viewModel.item?.id,
                      shown != DeletedItemBroadcaster.shared.lastDeletedItemID else { return }
                viewModel.track(Task { await viewModel.refreshItem() })
            }
    }

    /// Keyed on whether `viewModel.item` exists at all, not on `loadState`: a
    /// preloaded item makes that true before `load()` starts, so the real layout
    /// shows rather than a spinner. Falls back to the loading/error placeholders
    /// only when there's nothing to show.
    ///
    /// The offline check runs ahead of that branch while `loadState != .loaded`.
    /// A preload carries only the tapped card's shallow DTO; cast, episode list
    /// and rails arrive when `load()` completes, which `loadIfNeeded()` always
    /// triggers. If that fetch failed because the app is offline, showing the
    /// preload renders a half-populated page — hero image failing, sections
    /// missing, no explanation and no way back to an offline screen. Once
    /// `loadState` reaches `.loaded` the check stops applying, matching every
    /// other screen's rule that loaded content isn't blanked by a stale offline
    /// flag.
    @ViewBuilder
    private var content: some View {
        if ConnectivityMonitor.shared.isOffline, viewModel.loadState != .loaded {
            OfflineStateView(retry: { Task { await viewModel.load() } })
        } else if let item = viewModel.item {
            // AUDIO SUPPRESSION: the required safety net. `/Items/{itemId}` and
            // `/Items/{itemId}/Similar` have no server-side type filter, so an
            // audio item can reach here even with every list endpoint upstream
            // excluding it. Without this it falls to `default` and renders
            // `MovieDetailView`'s Play/Download UI for content that can't play.
            // Once audio playback is supported, rewire this to a real audio
            // detail view rather than deleting it.
            if item.isAudioContent {
                ErrorStateView(
                    message: String(localized: "Audio and music playback aren't supported in Dionysus Player yet."),
                    icon: "music.note"
                )
                .accessibilityIdentifier(A11yID.AssetDetail.unsupportedAudioMessage)
            } else {
                switch item.kind {
                case .series, .season, .episode:
                    // `.season`/`.episode` covers the moment before `load()`
                    // resolves, when `item` is still the tapped card's
                    // `preloadedItem` — a raw Season or Episode DTO, not yet
                    // swapped to the Show's item for a Season tap (see
                    // `AssetDetailViewModel.load()`). Once loaded, a Season tap
                    // reads `.series` and only an Episode tap still reads
                    // `.episode`; all three route here, which is what matters.
                    ShowDetailView(viewModel: viewModel)
                case .boxSet:
                    CollectionDetailView(viewModel: viewModel)
                case .playlist:
                    PlaylistDetailView(viewModel: viewModel)
                default:
                    MovieDetailView(viewModel: viewModel)
                }
            }
        } else {
            switch viewModel.loadState {
            case .idle, .loading, .loaded:
                LoadingView()
            case .failed(let message):
                ErrorStateView(message: message) { Task { await viewModel.load() } }
            }
        }
    }
}
