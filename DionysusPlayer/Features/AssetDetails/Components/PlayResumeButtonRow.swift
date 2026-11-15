import SwiftUI

/// The Play/Resume + Restart button row on the movie and show detail pages.
///
/// - Not-yet-watched: single "Play" button.
/// - Part-watched: "Resume" button (shortened to make room), a small
///   icon-only "Restart" button next to it, and a thin `dionysusProgress`
///   bar inset along the bottom of the primary button showing playback
///   progress (`resumeProgressOverlay`).
///
/// Favorite and watched live separately, in `HeroActionButtons` over the hero
/// image rather than in this row.
///
/// Versions (#289): the row says which button was tapped and the page
/// decides (`VersionedPlaybackStart`, through `versionHost`). What decides
/// is whether the title has a resume point, not the button: without one,
/// Play asks whenever `effectiveItem` has more than one version, the
/// remembered one marked; with one, Resume and Restart both play the
/// remembered version, and ask only when there is none (or it's gone).
/// The question points at the button tapped.
struct PlayResumeButtonRow: View {
    let item: MediaItem
    /// Show content plays a specific episode distinct from `item`, the Show
    /// itself, which has no resume position or version list — see
    /// `AssetDetailViewModel.showPlaybackEpisode` for how it's resolved. Passing
    /// it here gives the button its "Play S2:E4" label and is what the watched
    /// state and progress bar key off via `effectiveItem`.
    ///
    /// `nil` — a Movie, Show content whose episode hasn't resolved, or the
    /// episode-content case where `item` already is the thing to play — falls
    /// back to `item`'s own state, where an Episode's `episodeLabel` still
    /// produces the suffix.
    var targetEpisode: MediaItem? = nil
    /// Replaces `buttonTitle`'s suffix logic with `"Play \(titleOverride)"`.
    /// `PlaylistDetailView` is the only caller: a Playlist's button must name the
    /// member it will play ("Resume Toy Story", "Resume Top Gear S12:E9"), which
    /// the default logic can't produce, only ever adding an episode number.
    /// Doesn't affect action branching or the progress bar, which still key
    /// off `effectiveItem`.
    var titleOverride: String? = nil
    /// Play or Resume: one action, since whether it resumes is read from the
    /// title (`VersionedPlaybackStart.start`, `MediaItem.canResume`), never
    /// from the button, and the player starts from the saved position
    /// whenever there is one.
    var onStart: () -> Void
    /// Restart a part-watched item from 0.
    var onRestart: () -> Void
    /// The page's version-question state, so the question can anchor to the
    /// Play or Restart button that raised it
    /// (`versionedPlayback(_:anchor:viewModel:play:)`).
    var versionHost: VersionedPlaybackHost

    /// What the watched state, progress bar and label suffix all
    /// key off: `targetEpisode` when given, else `item`. See `targetEpisode`.
    private var effectiveItem: MediaItem { targetEpisode ?? item }

    /// "Play"/"Resume", with an "SXX:EYY" suffix whenever `effectiveItem` is an
    /// episode; `MediaItem.episodeLabel` is `nil` for anything else. A computed
    /// `String`, so it goes through `String(localized:)` rather than being
    /// auto-extracted, with the interpolated "SXX:EYY" left as unlocalized data
    /// like any other timecode-style label. `titleOverride` replaces the suffix
    /// scheme entirely.
    private var buttonTitle: String {
        if let titleOverride {
            return effectiveItem.canResume
                ? String(localized: "Resume \(titleOverride)")
                : String(localized: "Play \(titleOverride)")
        }
        switch (effectiveItem.canResume, effectiveItem.episodeLabel) {
        case (true, let suffix?):  return String(localized: "Resume \(suffix)")
        case (true, nil):          return String(localized: "Resume")
        case (false, let suffix?): return String(localized: "Play \(suffix)")
        case (false, nil):         return String(localized: "Play")
        }
    }

    /// `buttonTitle`'s spoken counterpart for Resume: "Resume from 11 minutes"
    /// rather than repeating the "SXX:EYY" suffix VoiceOver already got from the
    /// hero (see `BackdropLogoOverlay.episodeNumberAccessibilityText`). Falls
    /// back to `buttonTitle` for Play, or when there's nothing to resume from.
    private var accessibilityLabelText: String {
        guard effectiveItem.canResume, let resumeText = effectiveItem.resumePositionAccessibilityText else {
            return buttonTitle
        }
        return String(localized: "Resume from \(resumeText)")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onStart) {
                Label {
                    Text(buttonTitle)
                } icon: {
                    Image(systemName: "play.fill")
                }
                .frame(maxWidth: .infinity)
            }
            .primaryActionButtonStyle()
            .accessibilityLabel(accessibilityLabelText)
            // One identifier for both Play and Resume: the label changes with
            // watch state, the action doesn't, and a test shouldn't have to know
            // which it gets.
            .accessibilityIdentifier(A11yID.AssetDetail.playButton)
            .resumeProgressOverlay(effectiveItem.canResume ? effectiveItem.playedFraction : nil)
            .versionedPlayback(versionHost, anchor: .playButton)

            if effectiveItem.canResume {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .secondaryActionButtonStyle()
                // Without this, VoiceOver reads the SF Symbol's name ("arrow
                // counterclockwise") rather than what the button does.
                .accessibilityLabel(String(localized: "Restart"))
                .accessibilityIdentifier(A11yID.AssetDetail.restartButton)
                .versionedPlayback(versionHost, anchor: .restartButton)
            }
        }
    }
}
