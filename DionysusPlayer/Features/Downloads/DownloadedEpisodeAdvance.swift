import Foundation

/// A downloaded episode's player advancing to the next download (#274),
/// staged by `DownloadedAssetDetailView` from `PlayerView.onRequestNextDownload`
/// and resolved once the player has closed, so its `stop()` has already
/// written the finished episode's watched and resume state. A delete then
/// keeps an unsynced row as `markedForDeletion` until it syncs, so the
/// watched mark still reaches the server.
struct DownloadedEpisodeAdvance: Equatable {
    let finishedItemID: String
    let nextItemID: String
    /// Only Delete & Play Next sets it; the countdown never deletes.
    let deletesFinished: Bool
}

/// Where the page goes once an advance resolves.
enum DownloadedEpisodeAdvanceOutcome: Equatable {
    /// Show this download and present its player.
    case play(String)
    /// The next download went in the meantime: show this one, no player.
    case stay(String)
    /// Neither is left to show: leave the page rather than show
    /// "This download is no longer available."
    case leave
}

extension DownloadedEpisodeAdvance {
    @MainActor
    func resolve(store: DownloadStore, delete: (String) -> Void) -> DownloadedEpisodeAdvanceOutcome {
        if deletesFinished { delete(finishedItemID) }
        func isShowable(_ itemID: String) -> Bool {
            guard let item = store.item(itemID: itemID) else { return false }
            return item.status == .completed && !item.markedForDeletion
        }
        if isShowable(nextItemID) { return .play(nextItemID) }
        if isShowable(finishedItemID) { return .stay(finishedItemID) }
        return .leave
    }
}
