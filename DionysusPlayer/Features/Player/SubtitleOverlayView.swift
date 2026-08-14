import SwiftUI

/// Paints `PlayerViewModel.subtitleCues` over the video surface.
///
/// AetherEngine decodes and publishes subtitle cues but draws nothing
/// itself ("the engine emits `SubtitleCue`; your UI paints them" — see its
/// README) — this view is that UI. Mounted once in `PlayerView.body`,
/// between the video surface and the rest of the player chrome, and always
/// non-interactive so it never competes with taps meant for the controls
/// or the surface underneath.
struct SubtitleOverlayView: View {
    let viewModel: PlayerViewModel
    /// Matches whatever the video surface itself is doing — needed to work
    /// out the actual on-screen picture rect (as opposed to this view's own,
    /// possibly letterboxed, container) so image cues and `\pos`-anchored
    /// text cues land where the source authored them.
    let zoomMode: VideoZoomMode
    /// Whether `PlayerControlsOverlay`'s bottom transport row is currently
    /// on screen — default-positioned cues (the overwhelming majority: no
    /// explicit `\an`/`\pos`) sit just above it while showing, and settle
    /// back down near the screen edge once it fades.
    let controlsVisible: Bool

    /// `.compact` is iPhone's landscape signal — same check/caveat as
    /// `PlayerView.isLandscape` (stays `.regular` in both orientations on
    /// iPad). `PlayerControlsOverlay`'s transport row sits vertically
    /// *centered* between two `Spacer()`s in both orientations, not
    /// anchored to the bottom; portrait's tall screen leaves it well clear
    /// of a bottom-anchored subtitle regardless, but landscape's short
    /// screen puts that centered row much closer to the bottom edge, so
    /// clearing the scrubber bar (the actual bottom row) needs a smaller
    /// push there rather than portrait's — pushing a full 132pt up in a
    /// ~430pt-tall landscape screen lands squarely on the transport row
    /// instead of clearing it.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Bottom clearance while the transport row is showing, in portrait —
    /// enough to clear its gradient + scrubber + button row.
    private static let controlsClearance: CGFloat = 132
    /// Bottom clearance while showing in landscape — sized to clear just
    /// `PlayerControlsOverlay.scrubberBar` itself (its `.frame(height: 44)`
    /// track row plus its own `.padding()`, roughly 76pt) with a little
    /// margin, not measured — see `isLandscape`'s doc comment for why
    /// portrait's larger value overshoots here.
    private static let landscapeControlsClearance: CGFloat = 96
    /// Bottom clearance once controls have faded, just enough to clear the
    /// home indicator / safe area.
    private static let restingBottomInset: CGFloat = 28
    private static let horizontalInset: CGFloat = 24
    /// Matches `PlayerView.fadeOutAnimation`'s duration — the clearance
    /// change reads as part of the same controls fade rather than a
    /// separate, out-of-step motion.
    private static let clearanceAnimation: Animation = .easeInOut(duration: 0.3)

    var body: some View {
        GeometryReader { proxy in
            let video = videoRect(in: proxy.size)
            let cues = activeCues
            let defaultCues = cues.filter(isDefaultPositioned)
            let placedCues = cues.filter { !isDefaultPositioned($0) }

            ZStack {
                ForEach(placedCues) { cue in
                    placedCueView(cue, video: video)
                }

                if !defaultCues.isEmpty {
                    Color.clear
                        .frame(width: video.width, height: video.height)
                        .position(x: video.midX, y: video.midY)
                        .overlay(alignment: .bottom) {
                            VStack(spacing: 4) {
                                ForEach(defaultCues) { cue in
                                    textCueContent(cue)
                                }
                            }
                            .frame(maxWidth: video.width - Self.horizontalInset * 2)
                            .padding(.bottom, bottomInset)
                            .animation(Self.clearanceAnimation, value: controlsVisible)
                        }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    private var bottomInset: CGFloat {
        guard controlsVisible else { return Self.restingBottomInset }
        return isLandscape ? Self.landscapeControlsClearance : Self.controlsClearance
    }

    /// Cues active at `viewModel.sourceTime` — the cue list itself covers a
    /// window ahead of the playhead (for a host ADVANCE sync offset), so
    /// this is where "currently showing" actually gets decided. More than
    /// one cue can be active at once (a forced sign alongside dialogue),
    /// and all of them render, per AetherEngine's own docs.
    private var activeCues: [SubtitleCueDisplay] {
        let time = viewModel.sourceTime
        return viewModel.subtitleCues.filter { $0.startTime <= time && time < $0.endTime }
    }

    /// True for a text/rich-text cue with no explicit `\an`/`\pos` — the
    /// common case, stacked bottom-center as a group. Image cues always
    /// carry their own geometry, so they're never "default".
    private func isDefaultPositioned(_ cue: SubtitleCueDisplay) -> Bool {
        if case .image = cue.body { return false }
        return cue.placement == nil
    }

    @ViewBuilder
    private func placedCueView(_ cue: SubtitleCueDisplay, video: CGRect) -> some View {
        switch cue.body {
        case .image(let cgImage, let position, let canvasSize):
            imageCueView(cgImage, position: position, canvasSize: canvasSize, video: video)
        case .text, .richText:
            if let placement = cue.placement {
                textCueContent(cue)
                    .frame(maxWidth: video.width - Self.horizontalInset * 2)
                    .position(placementPoint(placement, video: video))
            }
        }
    }

    // MARK: - Text

    @ViewBuilder
    private func textCueContent(_ cue: SubtitleCueDisplay) -> some View {
        Group {
            switch cue.body {
            case .text(let string):
                Text(string)
            case .richText(let runs):
                richText(runs)
            case .image:
                EmptyView()
            }
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// `SubtitleTextRun`s concatenate into one styled `Text` via `+`,
    /// mirroring how AetherEngine itself flattens rich-text cues (`cue.text`)
    /// for consumers that don't care about styling — this is the consumer
    /// that does.
    private func richText(_ runs: [SubtitleCueDisplay.Run]) -> Text {
        runs.reduce(Text("")) { accumulated, run in
            var segment = Text(run.text)
            if let color = run.color { segment = segment.foregroundColor(color) }
            if run.isBold { segment = segment.bold() }
            if run.isItalic { segment = segment.italic() }
            if run.isUnderlined { segment = segment.underline() }
            if run.isStruckThrough { segment = segment.strikethrough() }
            return accumulated + segment
        }
    }

    /// ASS `\pos` wins when present (already normalized against the video
    /// frame, same as image geometry); otherwise falls back to the numpad
    /// `\an` alignment, defaulting to bottom-center (2) for a placement that
    /// somehow carries neither.
    private func placementPoint(_ placement: SubtitleCueDisplay.Placement, video: CGRect) -> CGPoint {
        if let position = placement.position {
            return CGPoint(x: video.minX + position.x * video.width, y: video.minY + position.y * video.height)
        }
        return alignmentPoint(placement.alignment ?? 2, video: video)
    }

    /// ASS numpad layout: 1–3 bottom row, 4–6 middle row, 7–9 top row, left
    /// to right within each — matches `SubtitleTextPlacement.alignment`'s
    /// own doc comment ("1 bottom-left through 9 top-right, 5 centred").
    private func alignmentPoint(_ alignment: Int, video: CGRect) -> CGPoint {
        let clamped = min(max(alignment, 1), 9)
        let column = (clamped - 1) % 3 // 0 left, 1 center, 2 right
        let row = (clamped - 1) / 3    // 0 bottom, 1 middle, 2 top
        let xFractions: [CGFloat] = [0.08, 0.5, 0.92]
        let yFractions: [CGFloat] = [0.92, 0.5, 0.08] // row 0 (bottom) near the bottom edge
        return CGPoint(x: video.minX + xFractions[column] * video.width, y: video.minY + yFractions[row] * video.height)
    }

    // MARK: - Image

    /// `position`/`canvasSize` are normalized `[0, 1]` against the
    /// composition canvas, same contract as `SubtitleImage` — see
    /// `SubtitleCueDisplay.Body.image`'s doc comment. The canvas maps onto
    /// `video` width-aligned and center-anchored (a cropped-video rip can
    /// author a canvas taller than the coded video), and `canvasSize ==
    /// .zero` collapses to canvas == video, which is exactly what falls out
    /// of this math when the canvas/video heights are equal.
    private func imageCueView(_ cgImage: CGImage, position: CGRect, canvasSize: CGSize, video: CGRect) -> some View {
        let canvasHeightOnScreen = canvasSize == .zero ? video.height : video.width * (canvasSize.height / canvasSize.width)
        let canvasOriginY = video.midY - canvasHeightOnScreen / 2
        let frame = CGRect(
            x: video.minX + position.minX * video.width,
            y: canvasOriginY + position.minY * canvasHeightOnScreen,
            width: position.width * video.width,
            height: position.height * canvasHeightOnScreen
        )
        return Image(decorative: cgImage, scale: 1)
            .resizable()
            .frame(width: max(frame.width, 0), height: max(frame.height, 0))
            .position(x: frame.midX, y: frame.midY)
    }

    // MARK: - Geometry

    /// Replicates the `resizeAspect`/`resizeAspectFill` math the video
    /// layer itself uses (`AetherPlaybackEngine.zoomMode`'s doc comment) so
    /// this view can place cues against the actual picture rect without
    /// needing access to AetherEngine's internal `AVPlayerLayer`/
    /// `videoRect`. Falls back to the full container before the natural
    /// size is known — nothing has cues to place before then anyway.
    private func videoRect(in containerSize: CGSize) -> CGRect {
        guard let natural = viewModel.videoNaturalSize, natural.width > 0, natural.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let containerAspect = containerSize.width / containerSize.height
        let videoAspect = natural.width / natural.height
        let fitsWidth = (zoomMode == .fit) == (videoAspect > containerAspect)
        let size = fitsWidth
            ? CGSize(width: containerSize.width, height: containerSize.width / videoAspect)
            : CGSize(width: containerSize.height * videoAspect, height: containerSize.height)
        let origin = CGPoint(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }
}
