import SwiftUI

/// The Play/Resume + Restart button row on the movie and show detail pages.
///
/// - Not-yet-watched: single "Play" button.
/// - Part-watched: "Resume" button (shortened to make room), a small
///   icon-only "Restart" button next to it, and a thin `dionysusProgress`
///   bar along the bottom of the primary button showing playback progress.
///
/// Favorite and watched live separately, in `HeroActionButtons` over the hero
/// image rather than in this row.
///
/// Version handling (see `MediaItem.mediaVersions`): "Resume" continues with
/// whatever version resume tracking already applies to, since Jellyfin's resume
/// position is per item rather than per version and there's nothing to choose.
/// "Play" and "Restart" are both fresh starts, so each prompts for a version
/// when `effectiveItem` has more than one, passing the choice to
/// `onPlay`/`onRestart` as a `MediaVersion.id` (`nil` when there was nothing to
/// choose). Callers remember it via
/// `AssetDetailViewModel.setPreferredMediaSourceID` so a later Resume can look
/// it up.
struct PlayResumeButtonRow: View {
    let item: MediaItem
    /// Show content plays a specific episode distinct from `item`, the Show
    /// itself, which has no resume position or version list — see
    /// `AssetDetailViewModel.showPlaybackEpisode` for how it's resolved. Passing
    /// it here gives the button its "Play S2:E4" label and is what the watched
    /// state, progress bar and version prompt key off via `effectiveItem`.
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
    /// Doesn't affect action branching, the progress bar or the version prompt,
    /// which still key off `effectiveItem`.
    var titleOverride: String? = nil
    /// Fresh start, receiving the chosen version's `MediaVersion.id` or `nil` when
    /// there was nothing to choose.
    var onPlay: (String?) -> Void
    /// Continue a part-watched item from its saved position; no version prompt,
    /// see this type's doc comment.
    var onResume: () -> Void
    /// Restart a part-watched item from 0, with the same version choice as
    /// `onPlay`.
    var onRestart: (String?) -> Void

    /// Which fresh-start action the version-choice `confirmationDialog` is
    /// resolving. Only meaningful while `isShowingVersionPrompt` is true (see
    /// `beginFreshStart(_:)`).
    @State private var pendingFreshStart: FreshStartAction = .play
    /// A plain `@State Bool` driven by `pendingFreshStart`, not a computed
    /// `Binding` derived from it being non-`nil`. The two read as equivalent, but
    /// a computed `Binding` as `confirmationDialog`'s `isPresented` was
    /// unreliable across repeated presentations: the third or fourth "Play" tap
    /// in one session silently skipped the prompt and used the server's default
    /// version. A stored `@State` projected directly is the documented pattern
    /// and didn't reproduce it.
    @State private var isShowingVersionPrompt = false

    private enum FreshStartAction { case play, restart }

    /// What the watched state, progress bar, version list and label suffix all
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
            return effectiveItem.isPartWatched
                ? String(localized: "Resume \(titleOverride)")
                : String(localized: "Play \(titleOverride)")
        }
        switch (effectiveItem.isPartWatched, effectiveItem.episodeLabel) {
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
        guard effectiveItem.isPartWatched, let resumeText = effectiveItem.resumePositionAccessibilityText else {
            return buttonTitle
        }
        return String(localized: "Resume from \(resumeText)")
    }

    /// Applied to both the button's border shape and the outer clip; matching them
    /// tucks the progress bar behind the button's curved edges.
    private let cornerRadius: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { effectiveItem.isPartWatched ? onResume() : beginFreshStart(.play) }) {
                Label {
                    Text(buttonTitle)
                } icon: {
                    Image(systemName: "play.fill")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
            .tint(.dionysusPrimary)
            .controlSize(.large)
            .accessibilityLabel(accessibilityLabelText)
            // One identifier for both Play and Resume: the label changes with
            // watch state, the action doesn't, and a test shouldn't have to know
            // which it gets.
            .accessibilityIdentifier(A11yID.AssetDetail.playButton)
            .overlay(alignment: .bottom) {
                if effectiveItem.isPartWatched, let fraction = effectiveItem.playedFraction {
                    GeometryReader { geo in
                        Color.dionysusProgress
                            .frame(width: geo.size.width * fraction)
                    }
                    .frame(height: 3)
                    .allowsHitTesting(false)
                }
            }
            // Clips button and overlay together to the rounded rect the button's
            // border shape uses, masking the progress bar's square corners.
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            if effectiveItem.isPartWatched {
                Button(action: { beginFreshStart(.restart) }) {
                    Image(systemName: "arrow.counterclockwise")
                        // Manual foreground: `.borderedProminent` defaults to
                        // white, which has poor contrast on a 70%-lightened tint.
                        .foregroundStyle(Color.dionysusPrimary)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
                .tint(.dionysusPrimaryLight)
                .controlSize(.large)
                // Without this, VoiceOver reads the SF Symbol's name ("arrow
                // counterclockwise") rather than what the button does.
                .accessibilityLabel(String(localized: "Restart"))
                .accessibilityIdentifier(A11yID.AssetDetail.restartButton)
            }
        }
        .confirmationDialog(
            "Choose a Version", isPresented: $isShowingVersionPrompt, titleVisibility: .visible
        ) {
            ForEach(effectiveItem.mediaVersions) { version in
                Button(version.label) { resolve(pendingFreshStart, mediaSourceID: version.id) }
            }
        }
    }

    /// Only prompts when there's a choice to make (`mediaVersions.count > 1`);
    /// otherwise resolves immediately with `nil`.
    private func beginFreshStart(_ action: FreshStartAction) {
        guard effectiveItem.mediaVersions.count > 1 else {
            resolve(action, mediaSourceID: nil)
            return
        }
        pendingFreshStart = action
        isShowingVersionPrompt = true
    }

    private func resolve(_ action: FreshStartAction, mediaSourceID: String?) {
        switch action {
        case .play: onPlay(mediaSourceID)
        case .restart: onRestart(mediaSourceID)
        }
        isShowingVersionPrompt = false
    }
}
