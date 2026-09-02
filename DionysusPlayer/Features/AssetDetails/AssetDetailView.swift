import SwiftUI

/// Loads an item and dispatches to the Movie or Show detail layout based on
/// its type.
///
/// `viewModel` is constructed *synchronously* in `init`, not lazily via
/// `.task` on a `@State private var viewModel: AssetDetailViewModel?` —
/// that pattern (the one every other feature's root view uses) always has
/// at least one render pass where the ViewModel is still nil, showing a
/// blank `LoadingView()` before `.task` gets a chance to run. Normally
/// that's an imperceptible flash, but building `viewModel` eagerly — with
/// `preloadedItem` already seeded into it (see `AppRoute.assetDetail`'s doc
/// comment) — skips it entirely: the very first frame already renders the
/// real hero header instead of a spinner.
struct AssetDetailView: View {
    let itemID: String
    @State private var viewModel: AssetDetailViewModel

    /// Bumped once `viewModel.loadIfNeeded()` (below) returns — forces a hard
    /// identity reset of `content` so the Movie/Show/Collection detail layout
    /// underneath is guaranteed to re-render with the now-fully-loaded
    /// `viewModel.item` (cast, technical details, similar/collections rails),
    /// not just whatever shallow `preloadedItem` it first rendered with.
    ///
    /// Exists because `viewModel.item` mutating on its own isn't reliably
    /// enough to get this page to pick it up — the same class of bug
    /// `MovieDetailView`/`ShowDetailView`/`CollectionDetailView`'s own
    /// `refreshTrigger` already works around for the *post-playback* refresh
    /// (see that property's doc comment), but until now nothing covered the
    /// *initial* load. Confirmed live (2026-08-30) reaching an item from a
    /// Home rail card (which seeds a preload — see `preloadedItem` below):
    /// intermittently, `MovieDetailView.body` itself would never re-run a
    /// second time after `load()` finished, even though direct instrumentation
    /// showed `viewModel.item` had already been correctly replaced with the
    /// full item (`loadState == .loaded`, cast/technical details present) —
    /// leaving the page permanently stuck showing only preload-level fields
    /// (year/rating/runtime/genres/overview) with no cast, no Details tab, no
    /// technical-format badges, and no Similar/Included-In rails, and no
    /// error or retry affordance since nothing had actually failed. Reached
    /// via Search (no preload, `item` starts `nil`) never reproduced it,
    /// since that path only ever renders `content` once, already fully
    /// loaded — this only race-loses when a shallow preload's render and the
    /// full load's completion are both vying for the same page.
    ///
    /// A plain `@State` write is what makes this reliable where re-reading
    /// `viewModel.item`/`viewModel.loadState` directly isn't — see
    /// `refreshTrigger`'s own doc comment for why. Scoped to bump right after
    /// `loadIfNeeded()` returns (whether or not this session actually had a
    /// preload to move past) rather than gating on `preloadedItem`'s
    /// presence — a redundant identity reset on the no-preload path is
    /// harmless (nothing to lose: the page hasn't been visible long enough
    /// for the user to have scrolled it), and keeping this unconditional
    /// avoids re-deriving "did this session need it" logic that could itself
    /// drift out of sync with `AssetDetailViewModel.load()`'s own behavior.
    @State private var loadCompletionTrigger = UUID()

    /// `client`/`userID` are passed in rather than read from
    /// `@Environment(AppState.self)` here directly, precisely so
    /// `viewModel` can be built *in* `init` — environment values aren't
    /// resolved yet at that point for this view, only for whichever
    /// ancestor (`AppRouteDestinationView`) constructs us.
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
            // Stops any favorite/watched toggle confirmation poll or
            // post-playback refresh still in flight the moment this page
            // is no longer on screen — see `AssetDetailViewModel
            // .cancelBackgroundWork()`'s doc comment. This is the one
            // reliable place for it: the actual screen-level owner of
            // `viewModel`, not a toolbar item or a sub-view that might not
            // get its own `.onDisappear` as predictably.
            .onDisappear { viewModel.cancelBackgroundWork() }
    }

    /// Keyed on whether `viewModel.item` exists at all, not on `loadState`
    /// — a preloaded item makes that true before `load()` has even started,
    /// so the real layout should already be showing rather than a spinner.
    /// Falls back to the loading/error placeholders only when there's truly
    /// nothing to show yet (no preload, fetch still in flight or failed).
    ///
    /// The offline check runs *first*, ahead of that preloaded-item branch,
    /// specifically when `loadState != .loaded` — a preload only ever
    /// carries the tapped card's shallow DTO (title/poster), not cast,
    /// episode list, similar/collections, etc.; those only arrive once
    /// `load()` (which `loadIfNeeded()` always still triggers even with a
    /// preload — see that method's own doc comment) actually completes. If
    /// that real fetch failed because the app is offline, showing the
    /// preload anyway silently renders a half-populated page — a hero
    /// image stuck failing to load and entire sections just missing, with
    /// no indication why, and no way back to an offline screen at all
    /// (confirmed live, 2026-08-18: tapping into an item from an
    /// already-offline cached Home screen left the app stuck exactly like
    /// this with no recovery). Once `loadState` does reach `.loaded`, this
    /// check stops applying — matching every other screen's rule that
    /// already-loaded content is never blanked out by a stale/background
    /// offline flag.
    @ViewBuilder
    private var content: some View {
        if ConnectivityMonitor.shared.isOffline, viewModel.loadState != .loaded {
            OfflineStateView(retry: { Task { await viewModel.load() } })
        } else if let item = viewModel.item {
            // AUDIO SUPPRESSION: the structurally-required safety net —
            // `/Items/{itemId}` (this screen's own fetch) and
            // `/Items/{itemId}/Similar` have no server-side type filter, so
            // an audio item can still reach here even with every list
            // endpoint upstream excluding it (e.g. via a Similar/"More Like
            // This" rail). Without this check it would fall to the
            // `default` case below and render `MovieDetailView`'s full
            // Play/Download UI for content that can't actually play. Once
            // Dionysus Player supports audio/music playback, rewire this to
            // a real audio detail view instead of deleting it.
            if item.isAudioContent {
                ErrorStateView(
                    message: String(localized: "Audio and music playback aren't supported in Dionysus Player yet."),
                    icon: "music.note"
                )
            } else {
                switch item.kind {
                case .series, .season, .episode:
                    // `.season`/`.episode` here covers the moment before
                    // `load()` resolves, when `item` is still whatever
                    // `preloadedItem` the tapped card handed in — a raw Season
                    // or Episode DTO, not yet swapped to the Show's own item for
                    // a Season tap (see `AssetDetailViewModel.load()`). Once
                    // loaded, a Season tap's `item.kind` is `.series` (the swap
                    // already happened) and only an Episode tap still reads
                    // `.episode` — both keep routing here either way, which is
                    // what actually matters: `ShowDetailView` renders correctly
                    // for all three by that point.
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
