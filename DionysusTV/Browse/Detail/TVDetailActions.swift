import SwiftUI

enum TVDetailFocus {
    static let play = "action.play"
    static let restart = "action.restart"
    static let watched = "action.watched"
    static let favorite = "action.favorite"
    static let overview = "overview"
}

/// Play or Resume, Restart, Watched and Favorite. There is no More button:
/// M3 has nothing to put in it.
///
/// `playTarget` is what plays (the movie, or the show's resolved episode;
/// `nil` when a show has nothing to play, where the Play button isn't
/// drawn). `statusTarget` is what Watched and Favorite act on: the movie, or
/// the show itself rather than the episode.
struct TVDetailActions: View {
    let viewModel: AssetDetailViewModel
    let playTarget: MediaItem?
    let statusTarget: MediaItem
    let isShow: Bool
    let focus: FocusState<String?>.Binding
    let play: (PlaybackRequest) -> Void

    private static func hasResume(_ target: MediaItem?) -> Bool {
        guard let target else { return false }
        return (target.resumePositionSeconds ?? 0) > 0 && !target.isPlayed
    }

    /// The ids in the order drawn, for the page's `tvClaimsFocus`.
    static func focusIDs(playTarget: MediaItem?) -> [String] {
        guard playTarget != nil else { return [TVDetailFocus.watched, TVDetailFocus.favorite] }
        return [TVDetailFocus.play] + (hasResume(playTarget) ? [TVDetailFocus.restart] : []) + [TVDetailFocus.watched, TVDetailFocus.favorite]
    }

    var body: some View {
        HStack(spacing: 22) {
            if let playTarget, let title = TVDetailFormat.playTitle(target: playTarget, isShow: isShow) {
                let hasResume = Self.hasResume(playTarget)
                Button {
                    play(PlaybackRequest(itemID: playTarget.id, mediaSourceID: viewModel.preferredMediaSourceID(forPlayableItem: playTarget.id)))
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "play.fill").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: title)
                            if hasResume, let left = TVDetailFormat.timeLeft(runTimeTicks: playTarget.dto.runTimeTicks, resumeSeconds: playTarget.resumePositionSeconds) {
                                HStack(spacing: 12) {
                                    ProgressView(value: playTarget.playedFraction ?? 0).tint(.dionysusHighlight).frame(width: 120)
                                    Text(verbatim: left).font(.caption.weight(.semibold))
                                }
                                .opacity(0.8)
                            }
                        }
                    }
                    .frame(minWidth: 320, alignment: .leading)
                }
                .focused(focus, equals: TVDetailFocus.play)
                .accessibilityIdentifier(A11yID.TV.Detail.play)

                if hasResume {
                    Button {
                        play(PlaybackRequest(itemID: playTarget.id, startFromBeginning: true, mediaSourceID: viewModel.preferredMediaSourceID(forPlayableItem: playTarget.id)))
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .focused(focus, equals: TVDetailFocus.restart)
                    .accessibilityLabel(String(localized: "Restart"))
                    .accessibilityIdentifier(A11yID.TV.Detail.restart)
                }
            }

            Button {
                Task { await viewModel.toggleWatched(itemID: statusTarget.id, currentlyWatched: statusTarget.isPlayed) }
            } label: {
                // The eye, never a tick.
                Image(systemName: statusTarget.isPlayed ? "eye.fill" : "eye")
            }
            .focused(focus, equals: TVDetailFocus.watched)
            .accessibilityLabel(statusTarget.isPlayed ? String(localized: "Mark as Unwatched") : String(localized: "Mark as Watched"))
            .accessibilityIdentifier(A11yID.TV.Detail.watched)

            Button {
                Task { await viewModel.toggleFavorite(itemID: statusTarget.id, currentlyFavorite: statusTarget.isFavorite) }
            } label: {
                Image(systemName: statusTarget.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(statusTarget.isFavorite ? Color.dionysusFavorite : .primary)
            }
            .focused(focus, equals: TVDetailFocus.favorite)
            .accessibilityLabel(statusTarget.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))
            .accessibilityIdentifier(A11yID.TV.Detail.favorite)
        }
        // The section spans the page's width, not just the buttons': Up
        // from anything below then reaches the row, even from a cast member
        // well to the right of Favorite, where tvOS found nothing above.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}
