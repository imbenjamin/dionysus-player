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
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.loadIfNeeded() }
    }

    /// Keyed on whether `viewModel.item` exists at all, not on `loadState`
    /// — a preloaded item makes that true before `load()` has even started,
    /// so the real layout should already be showing rather than a spinner.
    /// Falls back to the loading/error placeholders only when there's truly
    /// nothing to show yet (no preload, fetch still in flight or failed).
    @ViewBuilder
    private var content: some View {
        if let item = viewModel.item {
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
            default:
                MovieDetailView(viewModel: viewModel)
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
