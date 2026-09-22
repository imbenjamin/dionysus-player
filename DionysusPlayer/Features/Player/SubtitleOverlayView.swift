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
    /// Global y of the top edge of that chrome, from `BottomChromeTopKey`.
    /// `.infinity` until a layout pass reports it, which resolves to
    /// `restingBottomInset`.
    let controlsTop: CGFloat

    @Environment(\.displayScale) private var displayScale

    /// Breathing room between a subtitle and the chrome it clears.
    private static let controlsGap: CGFloat = 8
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
            let bottomInset = bottomInset(overlayMaxY: proxy.frame(in: .global).maxY)
            let cues = activeCues
            let defaultCues = cues.filter(isDefaultPositioned)
            let placedCues = cues.filter { !isDefaultPositioned($0) }

            ZStack {
                // libass owns the whole paint for an authored-ASS track — it
                // composites every line of the frame into one image, so the
                // app's own text rendering must not also run.
                if viewModel.isRenderingStyledASS {
                    assFrameView(
                        frame: proxy.size, video: video,
                        safeArea: Self.windowSafeAreaInsets, bottomInset: bottomInset
                    )
                } else {
                    ForEach(placedCues) { cue in
                        placedCueView(cue, video: video)
                    }
                }

                if !defaultCues.isEmpty, !viewModel.isRenderingStyledASS {
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

    /// Clearance at the bottom of the overlay, given where this overlay's own
    /// bottom edge sits globally.
    ///
    /// While the transport row is up this is derived from the chrome's MEASURED
    /// position (`BottomChromeTopKey`) rather than a constant. It used to be two
    /// constants, 132 portrait and 96 landscape, and the landscape one was
    /// calibrated against a scrubber row with nothing under it — 16 + 44 + 16,
    /// the "roughly 76pt" its own comment cited. The chapter/format row beneath
    /// the scrubber adds ~48pt whenever the content has chapters or a video
    /// format to name, which put the chrome at ~124pt and left a subtitle drawn
    /// straight through the scrubber in landscape. Content-dependent, so no
    /// constant can be right for both cases in either orientation.
    private func bottomInset(overlayMaxY: CGFloat) -> CGFloat {
        guard controlsVisible, controlsTop.isFinite else { return Self.restingBottomInset }
        return max(overlayMaxY - controlsTop + Self.controlsGap, Self.restingBottomInset)
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
        .accessibilityIdentifier(A11yID.Player.plainSubtitle)
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

    // MARK: - Authored ASS

    /// Paints the frame libass composited for `viewModel.sourceTime`.
    ///
    /// `imageRect` comes back in the coordinate space of libass' frame, which
    /// is the drawable region rather than the whole overlay (see
    /// `ASSSubtitleRenderSession.Geometry.drawable`), so its origin puts the
    /// image back where it belongs.
    @ViewBuilder
    private func assFrameView(
        frame: CGSize, video: CGRect, safeArea: UIEdgeInsets, bottomInset: CGFloat
    ) -> some View {
        let _ = viewModel.assFrameGeneration
        let drawable = ASSSubtitleRenderSession.Geometry(
            frame: frame, video: video, safeArea: safeArea,
            bottomInset: bottomInset, scale: displayScale
        ).drawable
        if let rendered = viewModel.assRenderSession.frame {
            Image(decorative: rendered.image, scale: 1)
                .resizable()
                .frame(width: rendered.imageRect.width, height: rendered.imageRect.height)
                .position(
                    x: drawable.minX + rendered.imageRect.midX,
                    y: drawable.minY + rendered.imageRect.midY
                )
                .accessibilityElement()
                .accessibilityLabel(viewModel.assRenderSession.dialogues(at: viewModel.sourceTime).joined(separator: " "))
                .accessibilityIdentifier(A11yID.Player.styledSubtitle)
        }
        // The geometry is only knowable here, and either it or the script can
        // arrive second — the view model holds whichever comes first.
        let report = { reportASSGeometry(frame: frame, video: video, safeArea: safeArea, bottomInset: bottomInset) }
        Color.clear
            .onAppear { report() }
            .onChange(of: frame) { report() }
            .onChange(of: video) { report() }
            .onChange(of: safeArea) { report() }
            // Same clearance the hand-rolled path above applies as bottom
            // padding, so both kinds of subtitle clear the transport row by the
            // same amount and settle back to the same resting position.
            .onChange(of: bottomInset) { report() }
    }

    /// The window's insets, not the overlay's.
    ///
    /// A `GeometryReader` inside a view that `ignoresSafeArea()` reports zero
    /// insets — measured, not assumed — and this overlay must ignore the safe
    /// area to sit over a full-bleed video. The window is the only place the
    /// real values survive.
    private static var windowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
    }

    private func reportASSGeometry(
        frame: CGSize, video: CGRect, safeArea: UIEdgeInsets, bottomInset: CGFloat
    ) {
        viewModel.setASSGeometry(
            ASSSubtitleRenderSession.Geometry(
                frame: frame,
                video: video,
                safeArea: safeArea,
                // The same live clearance the hand-rolled path uses, so a
                // styled cue sits exactly where an unstyled one would.
                //
                // This re-lays-out libass rather than shifting the composited
                // image, which is the point: the picture keeps its place
                // inside the frame, so only the bottom-aligned band moves and
                // `\pos` / `\an` signs stay on the anchors they were authored
                // against. Shifting the image would have dragged them along.
                bottomInset: bottomInset,
                scale: displayScale
            )
        )
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
