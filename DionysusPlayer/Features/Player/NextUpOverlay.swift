import SwiftUI

/// The in-player "Up Next" prompt for episodic content — a bottom-trailing
/// card showing the actual next episode (thumbnail, "SxEy · Title") with a
/// countdown ring, and Play Now / Cancel actions. See `PlayerViewModel
/// .nextUpSecondsRemaining`'s doc comment for where the countdown value
/// comes from, and `PlayerView`'s own doc comment on this overlay's
/// `.gesture`/`.opacity` treatment for why it's mounted independently of
/// `PlayerControlsOverlay` rather than as part of it.
///
/// Always mounted by `PlayerView`, with `isVisible` (`nextEpisode` and
/// `secondsRemaining` both non-nil) driving `.opacity`/`.allowsHitTesting` —
/// same "avoid a mount/unmount toggle fighting the ~10Hz time-update
/// re-renders" reasoning as `PlaybackStatsOverlay`/`PictureInPictureOverlay`.
/// Deliberately **not** gated by `showControls`: this is meant to be
/// complementary to the normal transport chrome, not a part of it, so it
/// stays shown and interactive whether the controls are faded in or out.
///
/// Kept deliberately small and mostly see-through (a plain translucent dark
/// fill, no `Material` — a system `Material` over the video surface read as
/// a much more opaque, flat gray card than it does over ordinary app
/// content, closer to a solid sheet than an overlay) so it reads as a
/// caption-sized hint sitting over the video rather than a modal blocking
/// it.
struct NextUpOverlay: View {
    let nextEpisode: MediaItem?
    let secondsRemaining: Int?
    /// The configured countdown length (`NextUpPreferenceStore
    /// .countdownSeconds`, passed through from `PlayerViewModel
    /// .nextUpTotalCountdownSeconds`) — the ring's trim needs this
    /// alongside `secondsRemaining` to know what fraction of the countdown
    /// is left; `secondsRemaining` alone (a plain elapsing count) has no
    /// notion of the starting point a fraction needs.
    let totalSeconds: Int?
    let onPlayNow: () -> Void
    let onCancel: () -> Void

    /// The thumbnail (and the countdown ring centered over it) is sized to
    /// match the episode-label/title text block next to it, rather than a
    /// fixed size — see `TextBlockHeightKey`. Seeded with a reasonable
    /// two-line-title guess so the thumbnail isn't oddly tiny for the one
    /// frame before the real measurement lands.
    @State private var textBlockHeight: CGFloat = 52

    private var isVisible: Bool { nextEpisode != nil && secondsRemaining != nil }

    /// Fraction of the countdown still remaining, for the ring's trim — `1`
    /// (a full circle) right as the countdown starts, shrinking to `0` as
    /// `secondsRemaining` counts down. `nil` (drawn as an empty ring) when
    /// there's nothing sensible to compute it from.
    private var remainingFraction: CGFloat? {
        guard let secondsRemaining, let totalSeconds, totalSeconds > 0 else { return nil }
        return CGFloat(secondsRemaining) / CGFloat(totalSeconds)
    }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                card
                    .padding(.trailing, 20)
                    // Clears the transport row (scrubber/buttons), which
                    // spans the full width near the bottom edge — see this
                    // view's own doc comment on why the two need to coexist
                    // rather than one hiding the other.
                    .padding(.bottom, 110)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
    }

    @ViewBuilder
    private var card: some View {
        if let nextEpisode {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    thumbnail(for: nextEpisode)
                    textBlock(for: nextEpisode)
                }

                HStack(spacing: 8) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                    Button("Play Now", action: onPlayNow)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(width: 260)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
        }
    }

    private func textBlock(for episode: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let episodeLabel = episode.episodeLabel {
                Text(episodeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(episode.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
        }
        // Reports its own rendered height back up via `TextBlockHeightKey`
        // so `thumbnail(for:)` can match it — see `textBlockHeight`'s doc
        // comment.
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: TextBlockHeightKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(TextBlockHeightKey.self) { textBlockHeight = $0 }
    }

    private func thumbnail(for episode: MediaItem) -> some View {
        AsyncRemoteImage(url: episode.thumbImageURL ?? episode.primaryImageURL, placeholderSystemImage: "play.tv")
            .frame(width: textBlockHeight * 16 / 9, height: textBlockHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { countdownRing }
    }

    /// The countdown, drawn as a shrinking ring over the thumbnail instead
    /// of a "Playing in Xs" line of text — a dark scrim behind it keeps the
    /// white stroke/number legible over a bright thumbnail frame.
    @ViewBuilder
    private var countdownRing: some View {
        if let secondsRemaining {
            ZStack {
                Circle().fill(.black.opacity(0.45))
                Circle().stroke(Color.white.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: remainingFraction ?? 0)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: secondsRemaining)
                Text("\(secondsRemaining)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
        }
    }
}

/// The max reported height of `NextUpOverlay`'s episode-label/title text
/// block — `reduce` takes the max rather than the latest value purely as a
/// defensive default for `PreferenceKey`'s contract (multiple views could
/// in principle report one), even though only a single text block ever
/// reports here in practice.
private struct TextBlockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
