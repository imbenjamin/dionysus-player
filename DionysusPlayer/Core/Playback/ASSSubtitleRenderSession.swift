import CoreGraphics
import CoreText
import Combine
import Foundation
import OSLog
import SwiftAssRenderer
import SwiftLibass

/// Renders authored ASS/SSA styling with libass, for subtitle tracks whose
/// styling the app's own overlay can't express.
///
/// **Why a whole script rather than the cue stream.** AetherEngine publishes
/// subtitle cues incrementally as the demuxer reads ahead, but libass renders
/// from a complete track: `swift-ass-renderer` exposes only `loadTrack` /
/// `reloadTrack`, and `reloadTrack` frees the current track synchronously, so
/// feeding it a growing script blinks the subtitle off on every rebuild. The
/// complete script is already available without any of that — Jellyfin extracts
/// any subtitle stream (embedded ones included) through
/// `JellyfinAPIClient.subtitleURL`, and `DownloadManager` stores every
/// non-bitmap track as a sidecar — so it is fetched once and loaded once. That
/// also means `LoadOptions.preserveASSMarkup` is never needed, which leaves the
/// engine's own cue path, and every non-ASS track on it, exactly as it was.
///
/// **Fonts.** A script naming a face the device lacks (retail typesetting and
/// fansub tracks both do) renders in a fallback face, which looks deliberate
/// rather than broken. The container's own font attachments are registered with
/// `CTFontManager` at process scope instead of going through fontconfig: the
/// wrapper's generated `fonts.conf` declares exactly one directory and no system
/// font paths, so the fontconfig provider would resolve embedded faces at the
/// cost of every system one. CoreText registration keeps both — verified
/// against a retail MKV whose script asks for "Agenda", where libass picks
/// `Agenda-MediumExtraCondensed` once registered and Helvetica otherwise.
///
/// **Geometry.** libass is given the whole overlay as its frame, with
/// `ass_set_margins` describing where the video sits inside it and
/// `ass_set_use_margins` allowing regular events into the empty area. That is
/// the documented mechanism for subtitles in the letterbox bar, and it happens
/// to draw the same distinction this app already makes by hand:
/// default-positioned dialogue moves below the picture in portrait, while
/// `\pos` / `\an` signs stay anchored to the frame they were authored against.
@MainActor
final class ASSSubtitleRenderSession {
    private static let log = Logger(subsystem: "com.dionysus.player", category: "ass-subtitles")

    /// Where the overlay should paint, and how libass was told to lay out.
    struct Geometry: Equatable {
        /// The whole overlay area, in points — libass' "frame".
        var frame: CGSize
        /// The picture inside it, in points.
        var video: CGRect
        /// Kept clear at the bottom of `frame`.
        ///
        /// Authored `MarginV` values are tiny — 1 script unit in one retail
        /// track measured here, under a point once scaled — because in a
        /// full-screen player the frame bottom IS the picture bottom. Here the
        /// frame runs to the physical screen edge, so honouring that margin
        /// literally puts dialogue under the home indicator, reading as
        /// clipped. Shrinking the frame moves the whole bottom-aligned band up
        /// by this much, matching what the app's own text path reserves.
        var bottomInset: CGFloat
        var scale: CGFloat

        /// Where libass' frame starts inside `frame`: the picture's top edge.
        ///
        /// The frame is shifted down rather than starting at the overlay's top
        /// so that there is NO top margin. `ass_set_use_margins` relocates every
        /// *regular* event into the margins, and top-aligned events are regular
        /// — so a top margin sends an `\an8` sign into the letterbox bar ABOVE
        /// the picture, which is exactly where a sign must not be (measured:
        /// y 9–23 against a picture starting at 324). With no top margin there
        /// is nowhere for it to go, and it lands on the picture where it was
        /// authored.
        ///
        /// The cost is `\an5`: middle-aligned regular events centre in the
        /// frame, and the frame is now the picture plus the bar below it, so a
        /// bare centred sign sits low. That is a real trade in libass' margin
        /// model — only a zero top margin places `\an8` correctly, only a
        /// symmetric one places `\an5` correctly, and the bottom bar this
        /// feature exists for rules out both being zero. `\an8` wins on
        /// frequency: typesetting uses it constantly, while a bare `\an5` is
        /// rare and almost always carries a `\pos`, which is positioned rather
        /// than regular and so is exempt from margins entirely.
        var renderOriginY: CGFloat { video.minY }

        /// What libass is actually given as its frame.
        var renderFrame: CGSize {
            CGSize(
                width: frame.width,
                height: max(frame.height - bottomInset - renderOriginY, 1)
            )
        }

        /// Where the picture sits relative to `renderFrame`, in renderer pixels.
        ///
        /// **Signed on purpose.** libass documents a negative margin as "the
        /// frame is inside the video, i.e. the video has been cropped", which is
        /// exactly the landscape case: the picture fills the screen, so the
        /// frame — which stops short of the transport chrome — is shorter than
        /// the picture and the bottom margin is negative. Clamping it to zero
        /// told libass the picture ended where the frame does, which mapped
        /// every `\pos` sign into a too-short rectangle (measured: a sign
        /// landing at y 20–34 against a correct 29–49, and 30% undersized).
        ///
        /// Portrait margins are positive — the picture really is smaller than
        /// the frame there — so the clamp never fired and this was landscape-only.
        var margins: (top: Int32, bottom: Int32, left: Int32, right: Int32) {
            let renderFrame = renderFrame
            func px(_ points: CGFloat) -> Int32 { Int32((points * scale).rounded()) }
            return (
                // Zero by construction: `renderOriginY` starts the frame at the
                // picture's top edge.
                top: px(video.minY - renderOriginY),
                bottom: px(renderFrame.height - (video.maxY - renderOriginY)),
                left: px(video.minX),
                right: px(renderFrame.width - video.maxX)
            )
        }
    }

    /// The latest frame libass produced, positioned in `geometry.frame`'s
    /// coordinate space, in points. `nil` when nothing is showing.
    private(set) var frame: ProcessedImage?

    var onFrameChange: (() -> Void)?

    private var renderer: AssSubtitlesRenderer?
    private var script: String?
    private var fonts: [ASSFontAttachment] = []
    /// Registered at PROCESS scope, so they outlive this object unless taken
    /// back. Tracked exactly so teardown can unregister what it registered and
    /// a later item can't inherit a previous one's faces.
    private var registeredFontURLs: [URL] = []
    private var fontDirectory: URL?
    private var geometry: Geometry?
    private var currentTime: TimeInterval = 0
    private var cancellables: Set<AnyCancellable> = []

    var isActive: Bool { renderer != nil }

    // MARK: - Track

    /// Install a complete ASS script plus whatever fonts the container carried.
    /// Re-installing the same inputs is a no-op.
    func load(script: String, fonts: [ASSFontAttachment], geometry: Geometry) {
        guard script != self.script || fonts != self.fonts || geometry != self.geometry else { return }
        if fonts != self.fonts {
            self.fonts = fonts
            registerFonts(fonts)
        }
        self.script = script
        self.geometry = geometry
        rebuild()
    }

    func teardown() {
        cancellables.removeAll()
        renderer?.freeTrack()
        renderer = nil
        script = nil
        geometry = nil
        fonts = []
        unregisterFonts()
        setFrame(nil)
    }

    // MARK: - Drive

    /// Re-lays-out for a new overlay size or picture rect — a rotation, a zoom
    /// change, or the natural size arriving after the first frame.
    ///
    /// Rebuilds the renderer rather than re-setting margins on the live one:
    /// `ass_set_margins` would have to be called from the main actor while the
    /// wrapper renders on its own queue, and geometry changes are rare enough
    /// that a re-parse is cheaper than getting that race right.
    func updateGeometry(_ geometry: Geometry) {
        guard geometry != self.geometry, script != nil else { return }
        self.geometry = geometry
        rebuild()
    }

    func setTime(_ seconds: TimeInterval) {
        currentTime = seconds
        renderer?.setTimeOffset(seconds)
    }

    /// Plain text of whatever is on screen, for the accessibility label a
    /// composited bitmap can't otherwise provide.
    func dialogues(at seconds: TimeInterval) -> [String] {
        renderer?.dialogues(at: seconds) ?? []
    }

    // MARK: - Setup

    private func rebuild() {
        guard let script, let geometry else { return }
        // Deliberately does NOT clear `frame`: a re-layout happens while a cue
        // is on screen (the transport row appearing), and dropping it would
        // blink the subtitle off for as long as the rebuild takes. The
        // subscription is cancelled first, so the outgoing renderer's own
        // teardown `nil` never lands; the stale bitmap simply stands for the
        // frame or two until the new one publishes.
        cancellables.removeAll()
        renderer?.freeTrack()
        renderer = nil
        let started = CFAbsoluteTimeGetCurrent()

        // Margins are the distance from the video rect to the frame, in the
        // renderer's own pixels — points × scale, matching what
        // `setCanvasSize` passes to `ass_set_frame_size`.
        let scale = geometry.scale
        let renderFrame = geometry.renderFrame
        let (top, bottom, left, right) = geometry.margins

        let renderer = AssSubtitlesRenderer(
            fontConfig: makeFontConfig(),
            rendererSetup: { _, handle in
                ass_set_margins(handle, top, bottom, left, right)
                ass_set_use_margins(handle, 1)
            }
        )
        self.renderer = renderer
        subscribe(to: renderer)
        renderer.setCanvasSize(renderFrame, scale: scale)
        renderer.loadTrack(content: script)
        renderer.setTimeOffset(currentTime)
        Self.log.debug(
            "libass track loaded: \(script.count)B frame=\(renderFrame.debugDescription) margins t\(top) b\(bottom) l\(left) r\(right) in \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - started) * 1000))ms"
        )
    }

    private func subscribe(to renderer: AssSubtitlesRenderer) {
        renderer
            .framesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                MainActor.assumeIsolated { self?.setFrame(image) }
            }
            .store(in: &cancellables)
    }

    private func setFrame(_ image: ProcessedImage?) {
        frame = image
        onFrameChange?()
    }

    /// `fontsPath` is unused by the CoreText provider — it only feeds the
    /// fontconfig `<dir>` — but `FontConfig` requires one.
    private func makeFontConfig() -> FontConfig {
        FontConfig(
            fontsPath: FileManager.default.temporaryDirectory,
            fontsCachePath: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fontProvider: .coreText
        )
    }

    // MARK: - Fonts

    private func registerFonts(_ fonts: [ASSFontAttachment]) {
        unregisterFonts()
        guard !fonts.isEmpty else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ass-fonts-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.log.error("ass font directory failed: \(error.localizedDescription)")
            return
        }
        fontDirectory = directory

        for font in fonts {
            // Attachment filenames come from the container and are not
            // sanitised there; a path separator would escape the directory.
            let safeName = font.filename.replacingOccurrences(of: "/", with: "_")
            let url = directory.appendingPathComponent(safeName)
            do {
                try font.data.write(to: url)
            } catch {
                Self.log.error("ass font write failed for \(safeName, privacy: .public)")
                continue
            }
            var cfError: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError) {
                registeredFontURLs.append(url)
            } else {
                // A duplicate face (the same font in two items) is the common
                // case and is not worth surfacing — libass resolves it either
                // way, from whichever registration is live.
                Self.log.debug("ass font not registered: \(safeName, privacy: .public)")
                cfError?.release()
            }
        }
        Self.log.debug("registered \(self.registeredFontURLs.count)/\(fonts.count) embedded fonts")
    }

    private func unregisterFonts() {
        for url in registeredFontURLs {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        }
        registeredFontURLs = []
        if let fontDirectory {
            try? FileManager.default.removeItem(at: fontDirectory)
            self.fontDirectory = nil
        }
    }
}
