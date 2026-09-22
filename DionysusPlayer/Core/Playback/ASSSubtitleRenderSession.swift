import CoreGraphics
import CoreText
import Combine
import Foundation
import OSLog
import SwiftAssRenderer
import UIKit
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
        /// The whole overlay area, in points.
        var frame: CGSize
        /// The picture inside it, in points.
        var video: CGRect
        /// The window's safe-area insets. The overlay itself deliberately
        /// ignores the safe area (it has to, to sit over a full-bleed video),
        /// so nothing else keeps subtitles out from under the rounded corners
        /// and the sensor housing.
        ///
        /// `UIEdgeInsets` rather than SwiftUI's `EdgeInsets` because these are
        /// PHYSICAL edges — a rounded corner does not move in a right-to-left
        /// layout — and because a `GeometryReader` inside an `ignoresSafeArea`
        /// view reports zeroes, so these come from the window (see
        /// `SubtitleOverlayView.windowSafeAreaInsets`).
        var safeArea: UIEdgeInsets
        /// Kept clear at the bottom for the transport chrome.
        ///
        /// Authored `MarginV` values are tiny — 1 script unit in one retail
        /// track measured here, under a point once scaled — because in a
        /// full-screen player the frame bottom IS the picture bottom. Here the
        /// frame runs to the physical screen edge, so honouring that margin
        /// literally puts dialogue under the home indicator.
        var bottomInset: CGFloat
        var scale: CGFloat

        /// The region libass may lay regular events out in.
        ///
        /// Not the whole overlay, and not the whole picture. Three things
        /// constrain it, and each was a real defect before it was applied:
        ///
        /// - **The picture's top edge.** `ass_set_use_margins` relocates every
        ///   *regular* event into the margins, and top-aligned events are
        ///   regular, so any room above the picture sends an `\an8` sign into
        ///   the letterbox bar above it (measured: y 9–23 against a picture
        ///   starting at 324).
        /// - **The safe area.** In landscape the picture fills the screen, so
        ///   the picture's own top-left corner is underneath the rounded corner
        ///   and the sensor housing — a corner-aligned sign drew there and was
        ///   physically cut off, invisible in a screenshot because the
        ///   framebuffer has no corners.
        /// - **The transport chrome**, via `bottomInset`.
        ///
        /// The bottom takes whichever of the chrome clearance and the safe-area
        /// inset is larger, so the resting position clears the home indicator
        /// by its real height rather than the approximation the constant was.
        var drawable: CGRect {
            let minX = max(video.minX, safeArea.left)
            let maxX = min(video.maxX, frame.width - safeArea.right)
            let minY = max(video.minY, safeArea.top)
            let maxY = frame.height - max(bottomInset, safeArea.bottom)
            return CGRect(
                x: minX, y: minY,
                width: max(maxX - minX, 1), height: max(maxY - minY, 1)
            )
        }

        /// What libass is given as its frame.
        var renderFrame: CGSize { drawable.size }

        /// Where the picture sits relative to `renderFrame`, in renderer pixels.
        ///
        /// **Signed on purpose.** libass documents a negative margin as "the
        /// frame is inside the video, i.e. the video has been cropped", which is
        /// exactly what a full-bleed picture is: the drawable region is smaller
        /// than the picture on every side that the safe area or the chrome cuts
        /// into. Clamping these to zero told libass the picture ended where the
        /// drawable region does, which mapped every `\pos` sign into the wrong
        /// rectangle (measured: a sign landing at y 20–34 against a correct
        /// 29–49, and 30% undersized).
        ///
        /// Portrait letterboxes, so its vertical margins are positive and the
        /// clamp never fired there — which is why this was landscape-only.
        var margins: (top: Int32, bottom: Int32, left: Int32, right: Int32) {
            let drawable = drawable
            func px(_ points: CGFloat) -> Int32 { Int32((points * scale).rounded()) }
            return (
                top: px(video.minY - drawable.minY),
                bottom: px(drawable.maxY - video.maxY),
                left: px(video.minX - drawable.minX),
                right: px(drawable.maxX - video.maxX)
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
