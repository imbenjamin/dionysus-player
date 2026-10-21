import SwiftUI

enum TVDetailFocus {
    static let play = "action.play"
    static let restart = "action.restart"
    static let watched = "action.watched"
    static let favorite = "action.favorite"
    static let more = "action.more"
    static let overview = "overview"
}

/// Play or Resume, Restart, Watched, Favorite and More Actions
/// (`TVMoreActionsButton`: Add to Playlist and Delete).
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
    /// A show's episode is still being resolved: Play is drawn already, so
    /// focus has somewhere to land and the row doesn't shift when it arrives.
    var isResolving = false
    /// What More Actions offers; `nil` draws no More button.
    var moreTargets: AssetActionTargets?
    let focus: FocusState<String?>.Binding
    let play: (PlaybackRequest) -> Void

    private static func hasResume(_ target: MediaItem?) -> Bool {
        guard let target else { return false }
        return target.canResume
    }

    /// The ids in the order drawn, for the page's `tvClaimsFocus`.
    static func focusIDs(playTarget: MediaItem?, isResolving: Bool = false, hasMore: Bool = false) -> [String] {
        let status = [TVDetailFocus.watched, TVDetailFocus.favorite] + (hasMore ? [TVDetailFocus.more] : [])
        guard playTarget != nil || isResolving else { return status }
        return [TVDetailFocus.play] + (hasResume(playTarget) ? [TVDetailFocus.restart] : []) + status
    }

    var body: some View {
        HStack(spacing: 22) {
            if playTarget != nil || isResolving {
                let title = TVDetailFormat.playTitle(target: playTarget, isShow: isShow) ?? String(localized: "Play")
                let hasResume = Self.hasResume(playTarget)
                Button {
                    guard let playTarget else { return }
                    play(PlaybackRequest(itemID: playTarget.id, mediaSourceID: viewModel.preferredMediaSourceID(forPlayableItem: playTarget.id)))
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "play.fill").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: title)
                            if hasResume, let playTarget, let left = TVDetailFormat.timeLeft(runTimeTicks: playTarget.dto.runTimeTicks, resumeSeconds: playTarget.resumePositionSeconds) {
                                TVResumeRow(fraction: playTarget.playedFraction ?? 0, timeLeft: left)
                            }
                        }
                    }
                    .frame(minWidth: 320, alignment: .leading)
                }
                .focused(focus, equals: TVDetailFocus.play)
                .accessibilityIdentifier(A11yID.TV.Detail.play)

                if hasResume, let playTarget {
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

            if let moreTargets {
                TVMoreActionsButton(viewModel: viewModel, targets: moreTargets, focus: focus)
            }
        }
        // The section spans the page's width, not just the buttons': Up
        // from anything below then reaches the row, even from a cast member
        // well to the right of Favorite, where tvOS found nothing above.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}

/// The resume bar and time left inside Play. Rose gold reads on the resting
/// glass, but on the focused button's near-white platter it drew about 1.9:1
/// (measured, the row being at 80% opacity), and even the deeper
/// `dionysusRoseGoldHighContrast`, opaque, only 2.6:1 against the track, the
/// focused platter lightening what it draws. So in focus the row is opaque
/// and the bar burgundy, as the iOS Play button's is in light mode
/// (Benjamin, 2026-10-20).
private struct TVResumeRow: View {
    let fraction: Double
    let timeLeft: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: fraction)
                .tint(isFocused ? Color.dionysusBurgundy : Color.dionysusHighlight)
                .frame(width: 120)
            Text(verbatim: timeLeft).font(.caption.weight(.semibold))
        }
        .opacity(isFocused ? 1 : 0.8)
    }
}
