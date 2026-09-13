import SwiftUI

/// Paints `PlayerViewModel.subtitleCues` over the video surface.
///
/// AetherEngine decodes and publishes subtitle cues but draws nothing itself;
/// this view is that UI. Mounted once in `PlayerView.body` between the video
/// surface and the rest of the player chrome, always non-interactive so it never
/// competes for taps.
struct SubtitleOverlayView: View {
    let viewModel: PlayerViewModel
    /// Matches what the video surface is doing, so the actual picture rect — as
    /// opposed to this view's possibly letterboxed container — can be derived and
    /// image and `\pos`-anchored cues land where the source authored them.
    let zoomMode: VideoZoomMode
    /// Whether `PlayerControlsOverlay`'s bottom transport row is on screen.
    /// Default-positioned cues — the majority, with no explicit `\an`/`\pos` —
    /// sit above it while showing and settle near the screen edge once it fades.
    let controlsVisible: Bool

    /// `.compact` is iPhone's landscape signal, with the same caveat as
    /// `PlayerView.isLandscape`: iPad stays `.regular` in both orientations.
    /// `PlayerControlsOverlay`'s transport row is vertically centered between two
    /// `Spacer()`s rather than bottom-anchored, so portrait's tall screen leaves
    /// it clear of a bottom subtitle while landscape's short screen puts it near
    /// the bottom edge — pushing portrait's full 132pt up in a ~430pt landscape
    /// screen lands on the transport row instead of clearing it.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Portrait bottom clearance while the transport row shows: enough for its
    /// gradient, scrubber and button row.
    private static let controlsClearance: CGFloat = 132
    /// Landscape bottom clearance, sized to clear just
    /// `PlayerControlsOverlay.scrubberBar` — its 44pt track row plus padding,
    /// roughly 76pt — with margin. See `isLandscape` for why portrait's larger
    /// value overshoots.
    private static let landscapeControlsClearance: CGFloat = 96
    /// Bottom clearance once controls have faded, just enough to clear the
    /// home indicator / safe area.
    private static let restingBottomInset: CGFloat = 28
    private static let horizontalInset: CGFloat = 24
    /// Matches `PlayerView.fadeOutAnimation`'s duration, so the clearance change
    /// reads as part of the controls fade rather than separate motion.
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

    /// Cues active at `viewModel.sourceTime`. The cue list covers a window ahead
    /// of the playhead for a host ADVANCE sync offset, so "currently showing" is
    /// decided here. More than one cue can be active at once — a forced sign
    /// alongside dialogue — and all render, per AetherEngine's docs.
    private var activeCues: [SubtitleCueDisplay] {
        let time = viewModel.sourceTime
        return viewModel.subtitleCues.filter { $0.startTime <= time && time < $0.endTime }
    }

    /// True for a text cue with no explicit `\an`/`\pos` — the common case,
    /// stacked bottom-center as a group. Image cues always carry geometry, so
    /// they're never default.
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

    /// `SubtitleTextRun`s concatenate into one styled `Text` via `+`, mirroring how
    /// AetherEngine flattens rich-text cues into `cue.text` for consumers that
    /// don't care about styling. This one does.
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

    /// ASS `\pos` wins when present, already normalized against the video frame
    /// like image geometry; otherwise the numpad `\an` alignment, defaulting to
    /// bottom-center (2) for a placement carrying neither.
    private func placementPoint(_ placement: SubtitleCueDisplay.Placement, video: CGRect) -> CGPoint {
        if let position = placement.position {
            return CGPoint(x: video.minX + position.x * video.width, y: video.minY + position.y * video.height)
        }
        return alignmentPoint(placement.alignment ?? 2, video: video)
    }

    /// ASS numpad layout: 1–3 bottom, 4–6 middle, 7–9 top, left to right within
    /// each, matching `SubtitleTextPlacement.alignment`.
    private func alignmentPoint(_ alignment: Int, video: CGRect) -> CGPoint {
        let clamped = min(max(alignment, 1), 9)
        let column = (clamped - 1) % 3 // 0 left, 1 center, 2 right
        let row = (clamped - 1) / 3    // 0 bottom, 1 middle, 2 top
        let xFractions: [CGFloat] = [0.08, 0.5, 0.92]
        let yFractions: [CGFloat] = [0.92, 0.5, 0.08] // row 0 (bottom) near the bottom edge
        return CGPoint(x: video.minX + xFractions[column] * video.width, y: video.minY + yFractions[row] * video.height)
    }

    // MARK: - Image

    /// `position`/`canvasSize` are normalized `[0, 1]` against the composition
    /// canvas, the same contract as `SubtitleImage` (see
    /// `SubtitleCueDisplay.Body.image`). The canvas maps onto `video`
    /// width-aligned and center-anchored, since a cropped-video rip can author a
    /// taller canvas than the coded video. `canvasSize == .zero` collapses to
    /// canvas == video, which falls out of this math when their heights are equal.
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

    /// Replicates the `resizeAspect`/`resizeAspectFill` math the video layer uses
    /// (see `AetherPlaybackEngine.zoomMode`), so cues can be placed against the
    /// real picture rect without access to AetherEngine's internal
    /// `AVPlayerLayer`. Falls back to the full container before the natural size
    /// is known, when there are no cues to place anyway.
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
