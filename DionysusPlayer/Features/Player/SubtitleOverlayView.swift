import SwiftUI

/// The sizes that differ between a phone at arm's length and a TV across the
/// room. `.phone` is what this overlay always drew.
struct SubtitleOverlayMetrics {
    var fontSize: CGFloat
    var horizontalInset: CGFloat
    /// Bottom clearance once the chrome has gone.
    var restingBottomInset: CGFloat
    /// Breathing room between a subtitle and the chrome it clears.
    var controlsGap: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var cornerRadius: CGFloat

    /// The resting inset is just enough to clear the home indicator / safe area.
    static let phone = SubtitleOverlayMetrics(
        fontSize: 20, horizontalInset: 24, restingBottomInset: 28, controlsGap: 8,
        horizontalPadding: 10, verticalPadding: 5, cornerRadius: 6
    )

    /// Sized for a 1920×1080pt screen viewed from a sofa. The font size
    /// matches Infuse's default on the same scene, photographed from the sofa
    /// (Bedroom Apple TV, 2026-10-08; 46pt was about a fifth smaller). The
    /// resting inset keeps a cue inside the title-safe area.
    static let tv = SubtitleOverlayMetrics(
        fontSize: 54, horizontalInset: 80, restingBottomInset: 60, controlsGap: 20,
        horizontalPadding: 22, verticalPadding: 10, cornerRadius: 12
    )
}

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
    var metrics: SubtitleOverlayMetrics = .phone

    @Environment(\.displayScale) private var displayScale
    @AppStorage(subtitleAppearanceStorageKey) private var appearance = subtitleAppearanceDefault

    /// Read per render, so a change in Settings reaches a cue already on screen.
    private var textStyle: SubtitleTextStyle {
        appearance == .system ? SystemCaptionStyle.shared.style : .dionysus
    }

    /// Matches `PlayerView.fadeOutAnimation`'s duration, so the clearance change
    /// reads as part of the controls fade rather than separate motion.
    private static let clearanceAnimation: Animation = .easeInOut(duration: 0.3)

    var body: some View {
        GeometryReader { proxy in
            let video = videoRect(in: proxy.size)
            let bottomInset = Self.bottomInset(
                controlsVisible: controlsVisible, controlsTop: controlsTop,
                overlayMaxY: proxy.frame(in: .global).maxY, metrics: metrics
            )
            let cues = activeCues
            let defaultCues = cues.filter(isDefaultPositioned)
            let placedCues = cues.filter { !isDefaultPositioned($0) }

            ZStack {
                if !cues.isEmpty {
                    UITestPictureMarker(video: video)
                }

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
                            .frame(maxWidth: video.width - metrics.horizontalInset * 2)
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
    static func bottomInset(
        controlsVisible: Bool, controlsTop: CGFloat, overlayMaxY: CGFloat, metrics: SubtitleOverlayMetrics
    ) -> CGFloat {
        guard controlsVisible, controlsTop.isFinite else { return metrics.restingBottomInset }
        return max(overlayMaxY - controlsTop + metrics.controlsGap, metrics.restingBottomInset)
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
                    .frame(maxWidth: video.width - metrics.horizontalInset * 2)
                    .position(placementPoint(placement, video: video))
            }
        }
    }

    // MARK: - Text

    @ViewBuilder
    private func textCueContent(_ cue: SubtitleCueDisplay) -> some View {
        let style = textStyle
        let scale = style.sizeScale
        let panel = RoundedRectangle(cornerRadius: metrics.cornerRadius * scale, style: .continuous)
        Group {
            switch cue.body {
            case .text(let string):
                Text(string)
            case .richText(let runs):
                richText(runs, style: style)
            case .image:
                EmptyView()
            }
        }
        .font(Self.font(style, size: metrics.fontSize * scale))
        .foregroundStyle(style.textColor.color)
        .multilineTextAlignment(.center)
        .modifier(SubtitleEdgeModifier(edge: style.edge, unit: metrics.fontSize * scale / 20))
        .padding(.horizontal, metrics.horizontalPadding * scale)
        .padding(.vertical, metrics.verticalPadding * scale)
        .background(style.background?.color ?? .clear, in: panel)
        .padding(style.window == nil ? 0 : metrics.verticalPadding * scale)
        .background(style.window?.color ?? .clear, in: panel)
        .accessibilityIdentifier(A11yID.Player.plainSubtitle)
    }

    /// A face chosen in Settings at that size, never scaled again by Dynamic
    /// Type (the system font here isn't either).
    private static func font(_ style: SubtitleTextStyle, size: CGFloat) -> Font {
        guard let name = style.fontName else { return .system(size: size, weight: .semibold) }
        return .custom(name, fixedSize: size)
    }

    /// `SubtitleTextRun`s concatenate into one styled `Text` via `+`, mirroring how
    /// AetherEngine flattens rich-text cues into `cue.text` for consumers that
    /// don't care about styling. This one does.
    private func richText(_ runs: [SubtitleCueDisplay.Run], style: SubtitleTextStyle) -> Text {
        runs.reduce(Text("")) { accumulated, run in
            var segment = Text(run.text)
            if let color = style.runColor(run.color) { segment = segment.foregroundColor(color) }
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

    /// Paints the frame libass composited for `viewModel.assRenderTime`.
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
        // Held back while a transcode's timing is unknown, which is the same
        // frame libass last drew at a now-stale time.
        if let rendered = viewModel.assRenderSession.frame, !viewModel.isStyledASSTimingPending {
            Image(decorative: rendered.image, scale: 1)
                .resizable()
                .frame(width: rendered.imageRect.width, height: rendered.imageRect.height)
                .position(
                    x: drawable.minX + rendered.imageRect.midX,
                    y: drawable.minY + rendered.imageRect.midY
                )
                .accessibilityElement()
                .accessibilityLabel(viewModel.assRenderSession.dialogues(at: viewModel.assRenderTime).joined(separator: " "))
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

    private func imageCueView(_ cgImage: CGImage, position: CGRect, canvasSize: CGSize, video: CGRect) -> some View {
        let frame = Self.imageCueFrame(
            position: position, canvasSize: canvasSize, codedSize: viewModel.videoNaturalSize, picture: video
        )
        return Image(decorative: cgImage, scale: 1)
            .resizable()
            .frame(width: max(frame.width, 0), height: max(frame.height, 0))
            .modifier(UITestImageCueMarker())
            .position(x: frame.midX, y: frame.midY)
    }

    // MARK: - Geometry

    private func videoRect(in containerSize: CGSize) -> CGRect {
        Self.pictureRect(
            in: containerSize, codedSize: viewModel.videoNaturalSize,
            pixelAspectRatio: viewModel.videoPixelAspectRatio, zoomMode: zoomMode
        )
    }

    /// Replicates the `resizeAspect`/`resizeAspectFill` math the video layer uses
    /// (see `AetherPlaybackEngine.zoomMode`), so cues can be placed against the
    /// real picture rect without access to AetherEngine's internal
    /// `AVPlayerLayer`. Falls back to the full container before the natural size
    /// is known, when there are no cues to place anyway.
    ///
    /// The picture's shape is the *displayed* one: the coded width times the
    /// pixel aspect ratio. Anamorphic video (720×576 at 16:9, 1440×1080)
    /// presents wider than it is coded, and the layer honours that, so a rect
    /// from the coded size alone was too tall and every cue was placed against
    /// the wrong picture.
    static func pictureRect(
        in containerSize: CGSize, codedSize: CGSize?, pixelAspectRatio: Double, zoomMode: VideoZoomMode
    ) -> CGRect {
        guard let coded = codedSize, coded.width > 0, coded.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let pixelAspect = pixelAspectRatio > 0 ? pixelAspectRatio : 1
        let containerAspect = containerSize.width / containerSize.height
        let videoAspect = coded.width * pixelAspect / coded.height
        let fitsWidth = (zoomMode == .fit) == (videoAspect > containerAspect)
        let size = fitsWidth
            ? CGSize(width: containerSize.width, height: containerSize.width / videoAspect)
            : CGSize(width: containerSize.height * videoAspect, height: containerSize.height)
        let origin = CGPoint(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    /// Where a bitmap cue lands on screen. `position`/`canvasSize` follow
    /// `SubtitleImage`'s contract (see `SubtitleCueDisplay.Body.image`):
    /// `position` is normalized `[0, 1]` against the canvas, and `canvasSize`
    /// is in the video's *coded* pixels. As AetherEngine documents it, the
    /// canvas maps onto the coded frame width-aligned and centre-anchored (a
    /// cropped-video rip authors a canvas taller than its video), and that
    /// rect then scales onto the displayed picture per axis. Mapping the
    /// canvas width-aligned onto the displayed picture directly makes it too
    /// tall on anamorphic video, dropping cues low or off the bottom. On
    /// square pixels the two agree. `canvasSize == .zero` (unknown) is the
    /// picture itself, and an unknown coded size falls back to treating the
    /// picture as square-pixelled.
    static func imageCueFrame(position: CGRect, canvasSize: CGSize, codedSize: CGSize?, picture: CGRect) -> CGRect {
        let canvasHeightOnScreen: CGFloat
        if canvasSize.width <= 0 || canvasSize.height <= 0 {
            canvasHeightOnScreen = picture.height
        } else if let coded = codedSize, coded.width > 0, coded.height > 0 {
            let canvasHeightInCodedPixels = coded.width * canvasSize.height / canvasSize.width
            canvasHeightOnScreen = canvasHeightInCodedPixels * picture.height / coded.height
        } else {
            canvasHeightOnScreen = picture.width * canvasSize.height / canvasSize.width
        }
        let canvasOriginY = picture.midY - canvasHeightOnScreen / 2
        return CGRect(
            x: picture.minX + position.minX * picture.width,
            y: canvasOriginY + position.minY * canvasHeightOnScreen,
            width: position.width * picture.width,
            height: position.height * canvasHeightOnScreen
        )
    }
}

/// The picture rect cues are placed against (`videoRect`), as an empty
/// element a journey can read, under the UI-test harness only and while a
/// cue is showing. Nothing on screen otherwise has that frame: the video
/// surface fills the container. Labelled (verbatim, never shown), so the
/// player's accessibility audits pass with it there.
private struct UITestPictureMarker: View {
    let video: CGRect

    var body: some View {
        #if DEBUG
        if UITestConfiguration.isActive {
            Color.clear
                .frame(width: video.width, height: video.height)
                .position(x: video.midX, y: video.midY)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: "Subtitle picture area"))
                .accessibilityIdentifier(A11yID.Player.subtitlePicture)
        }
        #endif
    }
}

/// Puts a bitmap cue in the accessibility tree under the UI-test harness
/// only, so a journey can read its frame. A picture of text has nothing for
/// VoiceOver to say, so everywhere else it stays decorative.
private struct UITestImageCueMarker: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if UITestConfiguration.isActive {
            content
                .accessibilityHidden(false)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: "Image subtitle"))
                .accessibilityIdentifier(A11yID.Player.imageSubtitle)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// The text's edge, in the system's vocabulary (`SubtitleTextStyle.Edge`).
/// `unit` is a point at the phone's 20pt, so the edge grows with the text.
private struct SubtitleEdgeModifier: ViewModifier {
    let edge: SubtitleTextStyle.Edge
    let unit: CGFloat

    func body(content: Content) -> some View {
        switch edge {
        case .softShadow:
            // Unscaled: the Dionysus look's shadow, on the phone and the TV.
            content.shadow(color: .black.opacity(0.9), radius: 2, y: 1)
        case .none:
            content
        case .dropShadow:
            content.shadow(color: .black.opacity(0.8), radius: 0.5 * unit, x: 1.5 * unit, y: 1.5 * unit)
        case .raised:
            content
                .shadow(color: .white.opacity(0.5), radius: 0, x: -0.75 * unit, y: -0.75 * unit)
                .shadow(color: .black.opacity(0.8), radius: 0, x: unit, y: unit)
        case .depressed:
            content
                .shadow(color: .black.opacity(0.8), radius: 0, x: -unit, y: -unit)
                .shadow(color: .white.opacity(0.5), radius: 0, x: 0.75 * unit, y: 0.75 * unit)
        case .outline:
            content
                .shadow(color: .black, radius: 0, x: unit, y: 0)
                .shadow(color: .black, radius: 0, x: -unit, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: unit)
                .shadow(color: .black, radius: 0, x: 0, y: -unit)
        }
    }
}
