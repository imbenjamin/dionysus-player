import SwiftUI

/// The in-player "Up Next" prompt for episodic content — a bottom-trailing
/// card showing the actual next episode (thumbnail, "SxEy · Title") with a
/// countdown ring, and Play Now / Cancel actions. See `PlayerViewModel
/// .nextUpSecondsRemaining`'s doc comment for where the countdown value
/// comes from, and `PlayerView`'s doc comment for why this overlay is
/// mounted independently of `PlayerControlsOverlay` rather than as part
/// of it.
///
/// Always mounted by `PlayerView`, with `isVisible` (`nextEpisode` and
/// `secondsRemaining` both non-nil) driving `.opacity`/`.allowsHitTesting` —
/// same "avoid a mount/unmount toggle fighting the ~10Hz time-update
/// re-renders" reasoning as `PlaybackStatsOverlay`/`PictureInPictureOverlay`.
/// Deliberately not gated by `showControls`: this is meant to be
/// complementary to the normal transport chrome, not a part of it, so it
/// stays shown and interactive whether the controls are faded in or out.
///
/// Kept deliberately small and mostly see-through (a plain translucent dark
/// fill, no `Material` — a system `Material` over the video surface reads
/// as a much more opaque, flat gray card than over ordinary app content,
/// closer to a solid sheet than an overlay) so it reads as a caption-sized
/// hint sitting over the video rather than a modal blocking it.
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
    /// The next download's artwork as a local file (#274), drawn instead of
    /// `nextEpisode`'s remote image, which a download's `MediaItem` has none of.
    var imageFileURL: URL? = nil
    /// Non-nil on a download's session (#274): Delete & Play Next takes Play
    /// Now's place, so the card keeps two actions. To play on without
    /// deleting, the viewer lets the countdown run (Benjamin, 2026-11-20).
    var onDeleteAndPlayNext: (() -> Void)? = nil

    /// The thumbnail (and the countdown ring centered over it) is sized to
    /// match the episode-label/title text block next to it, rather than a
    /// fixed size — see `TextBlockHeightKey`. Seeded with a reasonable
    /// two-line-title guess so the thumbnail isn't oddly tiny for the one
    /// frame before the real measurement lands.
    @State private var textBlockHeight: CGFloat = 52
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var stacksButtons: Bool { dynamicTypeSize.isAccessibilitySize }

    /// One line beside the other button; full width, wrapping as it must,
    /// when stacked.
    private func buttonTitle(_ title: LocalizedStringKey, stacked: Bool) -> some View {
        Text(title)
            .lineLimit(stacked ? nil : 1)
            .frame(maxWidth: stacked ? .infinity : nil)
    }

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
                    // view's doc comment on why the two need to coexist
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

    /// Built only while it shows; the overlay around it stays mounted (this
    /// view's doc comment). Hidden but built, it stayed in the accessibility
    /// tree after Cancel, its buttons with it, over Skip Credits in the same
    /// slot: `accessibilityHidden` on a mounted view didn't take it out.
    @ViewBuilder
    private var card: some View {
        if let nextEpisode, isVisible {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    thumbnail(for: nextEpisode)
                    textBlock(for: nextEpisode)
                }

                // Side by side, stacked full width at accessibility text sizes,
                // where two buttons in a row wrapped letter by letter
                // (Benjamin, 2026-11-20), and at any size where the row
                // doesn't fit: a label is never cut short.
                Group {
                    if stacksButtons {
                        buttonRow(stacked: true)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            buttonRow(stacked: false)
                            buttonRow(stacked: true)
                        }
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
            // Wide enough for Cancel and Delete & Play Next on one line at the
            // default text size (#274).
            .frame(width: 290)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(A11yID.Player.nextUpCard)
            .transition(.opacity)
        }
    }

    private func buttonRow(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button(action: onCancel) {
                buttonTitle("Cancel", stacked: stacked)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(A11yID.Player.nextUpCancel)
            if let onDeleteAndPlayNext {
                // Words only, no symbol, so it fits on one line beside Cancel
                // at the default size; styled exactly as Play Now, which it
                // replaces (Benjamin, 2026-11-20).
                Button(action: onDeleteAndPlayNext) {
                    buttonTitle("Delete & Play Next", stacked: stacked)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(Text("Deletes this episode's download from this device."))
                .accessibilityIdentifier(A11yID.Player.nextUpDeleteAndPlayNext)
            } else {
                // The ▶ matches the Apple TV's `TVNextUpCard`.
                Button(action: onPlayNow) {
                    Label("Play Now", systemImage: "play.fill")
                        .lineLimit(stacked ? nil : 1)
                        .frame(maxWidth: stacked ? .infinity : nil)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(A11yID.Player.nextUpPlayNow)
            }
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
        // Capped at accessibility text sizes, where matching the text's
        // height made it wider than the card and pushed the card off screen.
        let height = stacksButtons ? min(textBlockHeight, 64) : textBlockHeight
        return thumbnailImage(for: episode)
            // Decorative: the text beside it names the episode. Hidden on the
            // image alone, so the countdown ring over it still reads.
            .accessibilityHidden(true)
            .frame(width: height * 16 / 9, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { countdownRing }
    }

    @ViewBuilder
    private func thumbnailImage(for episode: MediaItem) -> some View {
        if let imageFileURL {
            LocalFileImage(url: imageFileURL, placeholderSystemImage: "play.tv")
        } else {
            AsyncRemoteImage(url: episode.thumbImageURL ?? episode.primaryImageURL, placeholderSystemImage: "play.tv")
        }
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
