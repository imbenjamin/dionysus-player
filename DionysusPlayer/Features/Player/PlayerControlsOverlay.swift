import SwiftUI

struct PlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    var onClose: () -> Void
    var onShowTracks: () -> Void

    /// Whether the scrubber's trailing timestamp reads as the asset's total
    /// duration (the default) or a `-`-prefixed countdown to the end —
    /// flipped by tapping that timestamp. Local `@State`: nothing outside
    /// this overlay needs to know which mode is showing.
    @State private var showRemainingTime = false

    var body: some View {
        VStack {
            topSection

            Spacer()

            transportControls

            Spacer()

            scrubberBar
        }
        .background(
            ZStack {
                // Corner-anchored, sitting mainly under the logo — see
                // `topSection`'s doc comment for why this lives here, on
                // the *whole* overlay, rather than scoped to that section's
                // own (much shorter) frame. A flat plateau out to 45% of
                // the radius, rather than fading immediately from the
                // corner, is deliberate: `.topLeading` is the *screen's*
                // true corner (this background ignores the safe area — see
                // below), which sits some distance above/left of the
                // logo's own safe-area-respecting position. A simple
                // 2-stop fade was already noticeably dimmer by the time it
                // reached that far, undershooting exactly the area this is
                // meant to cover; holding near-full opacity out past where
                // the logo actually sits, before tapering off, fixes that
                // without reintroducing a hard-edged cutoff — it still
                // reaches `.clear` well within the endRadius.
                //
                // Stretched wider than tall via `.scaleEffect` — a logo
                // wordmark is typically much wider than it is high (e.g.
                // "Office Space"), so a plain circular `RadialGradient`
                // left its right half sitting on unfaded video well before
                // the gradient's own falloff caught up, confirmed against a
                // real wide logo. Scaling from `.topLeading` keeps the
                // anchor corner fixed and stretches the circle into an
                // ellipse that reaches proportionally further right than
                // down, matching a wordmark's own proportions instead of a
                // uniform circle's.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black.opacity(0.85), location: 0),
                        .init(color: .black.opacity(0.85), location: 0.45),
                        .init(color: .clear, location: 1)
                    ]),
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 450
                )
                .scaleEffect(x: 1.8, y: 1, anchor: .topLeading)

                // Bottom-only — the scrubber's own legibility now comes
                // from `scrubberTrack`'s explicit track colors, not from
                // darkening behind it further.
                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            // Without this, the background is sized/positioned to this
            // VStack's own safe-area-respecting frame, not the true screen
            // bounds — same video-surface treatment `PlayerView` already
            // gives the player's video layer. Left off, the gradient falls
            // short of the physical edges (most visible in landscape, where
            // the safe-area inset is on the corner side this gradient is
            // meant to bleed into). The buttons/logo/scrubber themselves
            // stay out of this — only the background ignores the safe
            // area, so controls still avoid the sensor housing/home
            // indicator the way they should.
            .ignoresSafeArea()
        )
    }

    /// Close/track-selection buttons and the logo/title row. The
    /// corner-anchored gradient behind them lives on the *whole overlay's*
    /// background (the `ZStack` in `body`), not scoped to this section's
    /// own `VStack` — that was tried first and clipped the gradient hard:
    /// `.background()` clips its content to the view it's attached to, and
    /// this section's own frame (button row + logo, no `Spacer()`s) is only
    /// as tall as its content — well under the gradient's 320pt radius — so
    /// the fade got cut off mid-way instead of reaching `.clear`, visible
    /// as a hard horizontal line right under the logo. The *whole* overlay
    /// is comfortably taller than 320pt, so anchoring it there instead lets
    /// the same gradient actually finish fading out inside its own bounds.
    private var topSection: some View {
        VStack {
            HStack {
                // A proper close button, not a minimize/collapse affordance —
                // `onClose` always stops playback and reports a resume point
                // to the server (`PlayerViewModel.stop()`), it never leaves
                // the session running in the background, so the icon should
                // read as "exit playback" rather than "tuck this away".
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title2)
                }

                Spacer()

                Button(action: onShowTracks) {
                    Image(systemName: "captions.bubble")
                        .font(.title2)
                }
            }
            .foregroundStyle(.white)
            .padding()

            titleRow
        }
    }

    /// The rewind/play-pause/forward row — swapped for a centered spinner
    /// while `isBuffering`, rather than leaving the play/pause button
    /// showing a state that isn't actually available yet (tapping play
    /// mid-buffer did nothing perceptible, which read as broken rather than
    /// "in progress"). Covers both the initial buffer on load/resume and
    /// the re-buffer after a scrub — `PlaybackState.loading` and `.seeking`
    /// respectively, both already reported by `AetherPlaybackEngine`.
    @ViewBuilder
    private var transportControls: some View {
        if isBuffering {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.6)
                // Matches the play/pause button's own `.font(.system(size:
                // 44))` footprint, so nothing else in the layout shifts
                // when this swaps in and out.
                .frame(height: 44)
        } else {
            HStack(spacing: 40) {
                Button {
                    viewModel.seek(to: max(0, displayedTime - 15))
                } label: {
                    Image(systemName: "gobackward.15").font(.title)
                }

                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 44))
                }

                Button {
                    viewModel.seek(to: min(viewModel.duration, displayedTime + 30))
                } label: {
                    Image(systemName: "goforward.30").font(.title)
                }
            }
            .foregroundStyle(.white)
        }
    }

    private var isBuffering: Bool {
        viewModel.state == .loading || viewModel.state == .seeking
    }

    /// Logo preferred, pinned top-left — the same "logo over text-title
    /// fallback" convention `BackdropLogoOverlay` uses on the detail pages.
    /// Falls back to the plain title text when the item has no logo image at
    /// all, or when `LogoImageView` fails to load the one it has (a 404, a
    /// timeout after retries — see that type's doc comment). Contrast
    /// against the video behind it comes from the overlay's own background
    /// gradient (see `topSection`'s doc comment), not from anything owned
    /// here.
    @ViewBuilder
    private var titleRow: some View {
        if let item = viewModel.item {
            HStack {
                if let logoURL = item.logoImageURL {
                    LogoImageView(url: logoURL, fallback: titleText(item))
                        .frame(maxWidth: 240, maxHeight: 60, alignment: .leading)
                } else {
                    titleText(item)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private func titleText(_ item: MediaItem) -> some View {
        Text(item.name)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    /// Progress track with its timestamps at either end, rather than on
    /// their own row below it. The trailing timestamp doubles as a button —
    /// see `showRemainingTime`.
    private var scrubberBar: some View {
        VStack(spacing: 4) {
            if let format = viewModel.videoFormatDescription {
                Text(format)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }

            // `spacing: 16`, not the tighter 8 this used to be — the thumb
            // is a 20pt circle straddling the track's own edge (see
            // `scrubberTrack`'s doc comment), so it overflows a few points
            // past the track's declared bounds at either extreme. 8pt of
            // clearance wasn't enough room for that overflow to clear the
            // timestamp text next to it, so the thumb visibly overlapped
            // "0:05"/the end time whenever it sat at either end of the bar.
            // Applied here (once, symmetrically) rather than as one-sided
            // padding on `scrubberTrack` itself, so both ends keep equal
            // spacing.
            HStack(spacing: 16) {
                Text(Self.formatTime(displayedTime))
                    .monospacedDigit()

                scrubberTrack

                Button {
                    showRemainingTime.toggle()
                } label: {
                    Text(endTimeText)
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding()
    }

    /// A hand-drawn track rather than a plain `Slider` — SwiftUI's `Slider`
    /// only lets `.tint()` style the *elapsed* (filled) portion; the
    /// *remaining* (unfilled) portion always renders in the system's own
    /// low-opacity gray regardless of tint, which read as barely-there
    /// against a dark video frame. Drawing both segments directly gives
    /// control over the remaining segment's color too — `.opacity(0.35)`
    /// here vs. full white for elapsed, a deliberate step up from the
    /// system default rather than another background layer behind the
    /// whole bar.
    private var scrubberTrack: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = viewModel.duration > 0 ? min(1, max(0, displayedTime / viewModel.duration)) : 0

            ZStack(alignment: .leading) {
                // Both segments get their own explicit `height: 4` directly
                // — rather than relying on a `.frame(height: 4)` up on the
                // enclosing `ZStack` to propose that size down to them —
                // specifically so the 20pt thumb `Circle` below can't drag
                // the whole track taller with it. A shared parent frame
                // sizes to fit its *largest* child before the frame value
                // is applied to the children individually; pinning each
                // shape's own size is unambiguous regardless.
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.white)
                    .frame(width: width * fraction, height: 4)

                // Deliberately much larger than the 4pt track it sits on
                // top of — a native `Slider`'s thumb is the same way, a
                // sizable circle overlapping a thin line, rather than
                // matching the track's own thickness. Matters more here
                // than it would on a mouse-driven UI: on a real device this
                // is the actual finger touch target. The shadow (rather
                // than, say, a stroke) is what actually separates it from
                // the elapsed segment visually — both are solid white, so
                // without it the thumb only read as the track's leading
                // end looking slightly fatter, not as a distinct handle.
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: width * fraction - 10)
            }
            .frame(maxHeight: .infinity)
            // The visible track is a thin 4pt line, but the drag target
            // spans this whole `GeometryReader` frame (see `.frame(height:
            // 44)` below) — matches a plain `Slider`'s actual tap target,
            // which is much taller than what it visually draws.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isScrubbing = true
                        let newFraction = min(1, max(0, drag.location.x / width))
                        scrubTime = newFraction * viewModel.duration
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        viewModel.seek(to: scrubTime)
                    }
            )
        }
        .frame(height: 44)
        // A plain `Slider` gets VoiceOver adjustability for free; this
        // hand-rolled replacement needs it spelled out explicitly so
        // scrubbing isn't a regression for VoiceOver users.
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(Self.formatTime(displayedTime)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: viewModel.seek(to: min(viewModel.duration, displayedTime + 15))
            case .decrement: viewModel.seek(to: max(0, displayedTime - 15))
            @unknown default: break
            }
        }
    }

    /// The scrubber's trailing timestamp — the asset's total duration by
    /// default, or a countdown to the end once `showRemainingTime` is
    /// toggled on. Reads off `displayedTime` (the scrub-in-progress position
    /// while dragging, otherwise live playback position — see
    /// `displayedTime`), so the countdown keeps counting down as the user
    /// scrubs, not just during normal playback.
    private var endTimeText: String {
        guard showRemainingTime else { return Self.formatTime(viewModel.duration) }
        return "-" + Self.formatTime(max(0, viewModel.duration - displayedTime))
    }

    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : viewModel.currentTime
    }

    private static func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
