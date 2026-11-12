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

    struct Cue: Equatable {
        /// The page that plays it.
        var pageID: String
        /// For the download's page (`DownloadedAssetDetailView`), not the
        /// title's: both are keyed by the item id, and the title's page can
        /// still be on the stack the link replaces.
        var playsDownload = false
        /// A playlist member to play instead of the page's Play target, with
        /// the rest of the playlist after it (`play/<id>?playlist=`).
        var memberID: String?
        var overrides: PlaybackLinkOverrides
    }

    private(set) var cue: Cue?

    /// The page the cue is for, until that page takes it.
    var itemID: String? { cue?.pageID }

    func post(_ cue: Cue) { self.cue = cue }

    func post(itemID: String, memberID: String? = nil, overrides: PlaybackLinkOverrides = .init()) {
        post(Cue(pageID: itemID, memberID: memberID, overrides: overrides))
    }

    func clear() { cue = nil }

    /// Whether the cue is for `itemID`'s page, the title's or (`download`)
    /// its download's.
    func isFor(_ itemID: String, download: Bool = false) -> Bool {
        cue?.pageID == itemID && cue?.playsDownload == download
    }

    /// The cue, if it's for that page; taking it clears it, so it plays once.
    func take(for itemID: String, download: Bool = false) -> Cue? {
        guard let cue, isFor(itemID, download: download) else { return nil }
        self.cue = nil
        return cue
    }
}

extension View {
    /// Plays a cued link (`DeepLinkPlaybackCue`) once `viewModel` has loaded,
    /// by handing `play` what this page's Play would play, or the playlist
    /// member the link named (`AssetDetailViewModel.linkPlaybackRequest`). A
    /// page that has nothing to play drops the cue and says so. One that
    /// couldn't load is never shown; `AssetDetailView` drops its cue.
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
        let center = DeepLinkPlaybackCue.shared
        guard center.isFor(viewModel.itemID) else { return }
        switch viewModel.loadState {
        case .idle, .loading, .failed, .notFound:
            return
        case .loaded:
            guard let cue = center.take(for: viewModel.itemID) else { return }
            guard let request = viewModel.linkPlaybackRequest(memberID: cue.memberID, overrides: cue.overrides) else {
                let notices = cue.overrides.notices + [String(localized: "Nothing to play here.")]
                ToastCenter.shared.post(.notice(PlaybackLinkOverrides.combined(notices) ?? ""))
                return
            }
            play(request)
        }
    }
}
