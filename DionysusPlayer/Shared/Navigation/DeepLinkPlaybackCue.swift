import Observation
import SwiftUI

/// A play link waiting for its title's page (#406). `MainTabView` pushes the
/// page and posts the cue; the page takes it once it has loaded and plays
/// what its own Play would (`AssetDetailViewModel.linkPlaybackTarget`), with
/// its own player, so everything after (the queue, Next Up, the refresh on
/// close) is the page's ordinary behaviour.
@Observable
@MainActor
final class DeepLinkPlaybackCue {
    static let shared = DeepLinkPlaybackCue()

    /// The item whose page should play, until that page takes it.
    private(set) var itemID: String?

    func post(itemID: String) { self.itemID = itemID }

    func clear() { itemID = nil }

    /// Whether the cue is for `itemID`'s page; taking it clears it, so it
    /// plays once.
    func take(for itemID: String) -> Bool {
        guard self.itemID == itemID else { return false }
        self.itemID = nil
        return true
    }
}

extension View {
    /// Plays a cued link (`DeepLinkPlaybackCue`) once `viewModel` has loaded,
    /// by handing `play` what this page's Play would play. A page that has
    /// nothing to play drops the cue and says so. One that couldn't load is
    /// never shown; `AssetDetailView` drops its cue.
    func playsDeepLinkCue(_ viewModel: AssetDetailViewModel, play: @escaping (PlaybackRequest) -> Void) -> some View {
        modifier(DeepLinkCuePlayer(viewModel: viewModel, play: play))
    }
}

private struct DeepLinkCuePlayer: ViewModifier {
    let viewModel: AssetDetailViewModel
    let play: (PlaybackRequest) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: DeepLinkPlaybackCue.shared.itemID, initial: true) { takeCue() }
            .onChange(of: viewModel.loadState) { takeCue() }
    }

    private func takeCue() {
        let cue = DeepLinkPlaybackCue.shared
        guard cue.itemID == viewModel.itemID else { return }
        switch viewModel.loadState {
        case .idle, .loading, .failed, .notFound:
            return
        case .loaded:
            _ = cue.take(for: viewModel.itemID)
            guard let target = viewModel.linkPlaybackTarget else {
                ToastCenter.shared.post(.notice(String(localized: "Nothing to play here.")))
                return
            }
            play(PlaybackRequest(
                itemID: target.id,
                mediaSourceID: viewModel.preferredMediaSourceID(forPlayableItem: target.id)
            ))
        }
    }
}
