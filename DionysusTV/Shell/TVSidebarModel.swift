import Foundation
import Observation

/// The user's libraries, for the sidebar. Separate from `HomeViewModel`, which
/// fetches the same list for its own rail, because the sidebar outlives Home
/// and must not wait on Home's much larger load.
@MainActor
@Observable
final class TVSidebarModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed }

    private(set) var loadState: LoadState = .idle
    private(set) var libraries: [MediaItem] = []

    private let client: JellyfinAPIClient
    private let userID: String
    private var inFlightLoad: Task<Void, Never>?

    init(client: JellyfinAPIClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    /// Loads unless loaded; a failure is retried by the next call. The load
    /// runs in a task of its own, as `HomeViewModel.loadIfNeeded()`'s does, so
    /// a `TabView` rebuild cancelling the caller's `.task` doesn't cancel it,
    /// and a caller arriving mid-load joins it. Cancelled with the caller, the
    /// sidebar would be left without libraries for good.
    func loadIfNeeded() async {
        if let inFlightLoad {
            await inFlightLoad.value
            return
        }
        guard loadState == .idle || loadState == .failed else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.load()
        }
        inFlightLoad = task
        await task.value
        inFlightLoad = nil
    }

    private func load() async {
        loadState = .loading
        do {
            let images = await client.makeImageURLBuilder()
            let views = try await client.userViews(userID: userID)
            // AUDIO SUPPRESSION: as Home's library rail.
            libraries = views.items.map { MediaItem(dto: $0, images: images) }.filter { !$0.isAudioLibrary }
            loadState = .loaded
        } catch {
            loadState = .failed
        }
    }
}
