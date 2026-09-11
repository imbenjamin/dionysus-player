import CoreGraphics
import SwiftUI

/// This default and `ProfileView`'s `@AppStorage` default are declared by hand
/// in both places, with nothing enforcing they stay in sync.
let chaptersInScrubberEnabledStorageKey = "chaptersInScrubberEnabled"
/// Chapters in the scrubber are opt-out, matching every other chapter surface —
/// the rail, the current-chapter button, the picker — being on whenever chapters
/// exist. This one is escapable for anyone who finds the snap distracting.
let chaptersInScrubberEnabledDefault = true

struct PlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    /// Whether the track picker is showing. A `@Binding` rather than local
    /// `@State` because `PlayerView`'s auto-hide timer needs it too: otherwise
    /// the timer can't tell the picker is open and fades the controls row out
    /// from under it, panel and all.
    @Binding var isShowingTrackPicker: Bool
    /// Whether the chapter picker is showing, a `@Binding` for the same reason
    /// `isShowingTrackPicker` is.
    @Binding var isShowingChapterPicker: Bool
    var onClose: () -> Void
    /// The three toggle buttons take state in and report taps out through a
    /// closure rather than binding: `PlayerView` owns each, and none has a
    /// continuous in-overlay gesture needing to write back as the scrubber does.
    var isRotationLocked: Bool
    var onToggleRotationLock: () -> Void
    var isPlaybackStatsVisible: Bool
    var onTogglePlaybackStats: () -> Void
    /// Zoom is landscape-only, so this button is gated on `isLandscapeWindow`
    /// like `PlayerView`'s double-tap and pinch gestures.
    var zoomMode: VideoZoomMode
    var onToggleZoomMode: () -> Void
    /// Whether the window is wider than tall, measured by `PlayerView` via
    /// `.onGeometryChange`.
    ///
    /// Distinct from this file's `isLandscape` (`verticalSizeClass == .compact`),
    /// which answers "is this window short" — what the chapter picker's bottom
    /// padding needs. This answers "is it landscape-shaped", which the size class
    /// cannot on iPad.
    var isLandscapeWindow: Bool
    /// One-shot, unlike the toggle buttons: `isPictureInPicturePossible` alone
    /// decides whether the button is enabled, and once tapped there is nothing
    /// for this overlay to reflect — the "Playing in Picture in Picture"
    /// placeholder lives in `PlayerView`.
    var onEnterPictureInPicture: () -> Void
    /// Called on every button tap and scrubber-drag tick, resetting
    /// `PlayerView`'s auto-hide countdown so an interaction isn't cut off
    /// mid-way. Not called from `onClose`, where playback is ending, or the
    /// timestamp toggle, which changes too little to warrant it.
    var onInteract: () -> Void
    /// A tap on blank space within this overlay while the controls are visible.
    /// `PlayerView` hides them at once rather than making the user wait out the
    /// auto-hide delay. A plain tap gesture on the full-overlay catcher suffices
    /// to catch only blank taps: buttons, the scrubber and the picker's backdrop
    /// all sit above it and claim their own.
    var onDismissControls: () -> Void

    /// Whether the trailing timestamp counts down to the end, the default, or
    /// shows total duration. Flipped by tapping it; local, since nothing outside
    /// this overlay needs to know.
    @State private var showRemainingTime = true

    #if DEBUG
    /// Mirrors `LogoImageView`'s otherwise-invisible `showFallback` for
    /// `titleRow`'s logo, needed because this row's
    /// `.accessibilityElement(children: .ignore)` collapses its children.
    /// Compiled out of Release.
    @State private var isLogoFallbackVisible = false
    #endif
    /// Whether the info-circle button that toggles `PlaybackStatsOverlay` is
    /// shown. A persisted setting read directly here rather than threaded down
    /// from `PlayerView`. Its default must match
    /// `AdvancedPlaybackSettingsView`'s read of the same key.
    @AppStorage(showPlaybackStatsButtonEnabledStorageKey) private var isPlaybackStatsButtonEnabled = showPlaybackStatsButtonEnabledDefault

    /// "Is this window short", not "is it landscape": `.compact` is iPhone's
    /// landscape signal and stays `.regular` on iPad either way. Only the chapter
    /// picker's bottom padding reads it; the zoom button uses
    /// `isLandscapeWindow`.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Every colour here is white at some opacity, so without this the player
    /// ignores Increase Contrast on the screen most likely to have it on. Raises
    /// the low-opacity values toward opaque and deepens `controlScrim` rather
    /// than swapping palettes: there is no colour to re-tint, only contrast to
    /// add.
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    private var isIncreasedContrast: Bool { colorSchemeContrast == .increased }

    /// Secondary text — timestamps, the episode subtitle — at `0.8` white, or
    /// opaque under Increase Contrast.
    private var secondaryTextOpacity: Double { isIncreasedContrast ? 1 : 0.8 }

    /// A dark halo behind a white glyph. `backgroundGradient` covers only the
    /// top-left corner and a bottom fade, so the transport cluster and
    /// top-trailing buttons sit on unmodified video: on a bright frame only 2%
    /// of positions around a glyph cleared HIG's 3:1 non-text minimum, median
    /// 1.64:1 and a floor of 1.00:1. With this, 89% and median 6.31:1.
    ///
    /// A shadow rather than a plate: it costs nothing on dark frames that are
    /// already fine, so the chrome-free look survives. It buys perceptual
    /// separation from an edge rather than raising the glyph's own ratio — the
    /// ceiling for white-on-arbitrary-video short of an opaque plate.
    private var controlScrim: some ViewModifier {
        ControlScrim(opacity: isIncreasedContrast ? 1 : 0.8,
                     radius: isIncreasedContrast ? 7 : 5)
    }

    /// Top-row tap target, on-state badge and glyph, in a 44 : 36 : 22 ratio.
    /// All three scale together: scaling only the glyph made it outgrow its
    /// fixed badge at AX3XL and spill out, reading as a rendering fault.
    ///
    /// Clamped, unlike the picker row heights: this row carries up to six
    /// buttons, and unbounded growth overflows a narrow phone long before an
    /// iPad runs out of room. The caps hold the ratio.
    @ScaledMetric(relativeTo: .title2) private var scaledTopControlSize: CGFloat = 44
    private var topControlSize: CGFloat { min(scaledTopControlSize, 60) }
    @ScaledMetric(relativeTo: .title2) private var scaledTopBadgeSize: CGFloat = 36
    private var topBadgeSize: CGFloat { min(scaledTopBadgeSize, 49) }
    @ScaledMetric(relativeTo: .title2) private var scaledTopGlyphSize: CGFloat = 22
    private var topGlyphSize: CGFloat { min(scaledTopGlyphSize, 30) }

    /// Transport-row tap target, skip glyph and play/pause glyph, in a
    /// 44 : 28 : 44 ratio. Scaling together is the point: `.title` scales and
    /// `.system(size: 44)` doesn't, so at AX3XL the skip buttons rendered larger
    /// than play/pause and both overflowed their frames.
    @ScaledMetric(relativeTo: .title) private var scaledTransportSize: CGFloat = 44
    private var transportSize: CGFloat { min(scaledTransportSize, 72) }
    @ScaledMetric(relativeTo: .title) private var scaledSkipGlyphSize: CGFloat = 28
    private var skipGlyphSize: CGFloat { min(scaledSkipGlyphSize, 46) }
    @ScaledMetric(relativeTo: .title) private var scaledPlayGlyphSize: CGFloat = 44
    private var playGlyphSize: CGFloat { min(scaledPlayGlyphSize, 72) }

    /// Whether the scrubber shows chapter dividers and snaps to them. A persisted
    /// setting read directly here, whose default must match `ProfileView`'s read
    /// of the same key.
    ///
    /// Does not gate the current-chapter button or `ChapterPickerOverlay`, which
    /// stay available regardless — only the dividers and the magnetic snap.
    @AppStorage(chaptersInScrubberEnabledStorageKey) private var isChaptersInScrubberEnabled = chaptersInScrubberEnabledDefault

    /// Whether a touch is down on the scrubber track, as opposed to the
    /// `isScrubbing` binding, which stays `true` through the issued seek landing
    /// rather than only the drag. Local: nothing outside needs to know a touch is
    /// down specifically, only that scrubbing is in progress.
    @State private var isDraggingScrubber = false

    /// Latest resolved scrub-preview still, shown by `ScrubThumbnailPreview`
    /// while `isDraggingScrubber`. Deliberately not cleared between fetches
    /// — a `nil` result from `viewModel.scrubThumbnail(atSeconds:)` means
    /// "not available yet", not "no thumbnail exists", so this keeps
    /// whatever it last had rather than flashing blank. Reset only
    /// implicitly, by the next drag's first successful fetch overwriting it.
    @State private var scrubThumbnailImage: CGImage?
    /// A scheduled/in-flight scrub-thumbnail fetch, or `nil` when none is
    /// pending — see `requestScrubThumbnail(at:)`'s doc comment for the
    /// throttle (not debounce) shape this drives.
    @State private var scrubThumbnailTask: Task<Void, Never>?
    /// The latest drag position requested — always kept current by every
    /// `.onChanged` tick, independent of whether a fetch is actually
    /// scheduled right now. When a throttled fetch finally runs, it reads
    /// *this* rather than whatever position was current when it was
    /// scheduled, so a burst of ticks collapses into one fetch at the
    /// drag's latest position rather than a stale in-between one.
    @State private var pendingScrubSeconds: TimeInterval?
    /// When the last scrub-thumbnail fetch actually started — the
    /// throttle's own clock, measured from real elapsed time rather than
    /// "time since the last drag tick" (which is what a debounce, the
    /// shape this replaced, would key off instead).
    @State private var lastScrubThumbnailFireDate: Date?

    /// Which chapter the in-progress drag is currently magnetically snapped
    /// to, by index into `viewModel.chapters` — `nil` whenever the finger is
    /// outside every boundary's `chapterSnapRadius`. Purely a
    /// *transition* detector for the haptic below; the snapped *time* itself
    /// is written straight to `scrubTime` and needs no separate state.
    @State private var snappedChapterIndex: Int?
    /// Flipped, never read, on each transition into a new snapped chapter:
    /// `.sensoryFeedback(_:trigger:)` fires on any change of its trigger. Not
    /// flipped on leaving a snap zone or on repeat frames within one, so a drag
    /// through a boundary ticks once rather than buzzing while the finger
    /// lingers.
    @State private var chapterSnapHapticTrigger = false

    /// A fixed cap rather than a measured fraction of the screen: reading the
    /// real height via `GeometryReader` or a `PreferenceKey` left the panel
    /// rendering nowhere, the dead end `estimatedHeight(for:)` also documents.
    /// Sized for landscape iPhone, this player's primary orientation.
    private static let trackPickerMaxHeight: CGFloat = 320
    /// The panel's width, named alongside `trackPickerMaxHeight` rather than
    /// left as a literal on `trackPickerContent`'s frame.
    private static let trackPickerIdealWidth: CGFloat = 320
    private static let trackPickerMaxWidth: CGFloat = 360

    /// One constant so the panel's open and close feel identical across the
    /// several sites that toggle `isShowingTrackPicker`: the button, the backdrop
    /// tap, and each row's selection.
    private static let trackPickerAnimation: Animation = .easeOut(duration: 0.18)

    /// Drill-down and back between picker pages: slower and `.easeInOut`, matching
    /// `UINavigationController`'s push and pop, rather than
    /// `trackPickerAnimation`'s snappier pop-open.
    private static let trackPickerNavigationAnimation: Animation = .easeInOut(duration: 0.3)

    var body: some View {
        ZStack {
            // Decorative, and backmost on purpose: a `.background()`'s drawn
            // content occludes hit-testing behind it, so attaching this gradient
            // to `content` blocks every tap meant for the catcher below, across
            // the whole overlay rather than only where it reads as opaque.
            backgroundGradient

            // Blank-space tap catcher covering the whole overlay: every control
            // in `content` draws in front and claims its own tap, so this
            // receives only taps nothing else wanted.
            //
            // Covering everything rather than a middle band matters:
            // `topSection` and `scrubberBar` have no `.contentShape`, so blank
            // taps within them fall through to `PlayerView`'s video gesture,
            // which only toggles, and only after the double-tap window. In
            // landscape that is most of the screen. Z-order plus every control's
            // ≥44×44pt `.contentShape` covers it with no hand-carved band.
            //
            // Needs a nearly-invisible fill: SwiftUI won't hit-test a fully
            // clear shape.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Defensive: either picker's backdrop is added by a later
                    // `.overlay` and so claims a tap first while open, but don't
                    // rely on z-order alone.
                    guard !isShowingTrackPicker, !isShowingChapterPicker else { return }
                    onDismissControls()
                }

            content
        }
        // Full-screen invisible tap catcher, in its own `.overlay` before the
        // panel's, so the panel sits on top and keeps its own taps while
        // anything elsewhere falls through here and closes the picker. Needs a
        // hit-testable fill, since SwiftUI ignores a fully clear shape. Without
        // it a dismissing tap reaches the blank-space catcher above, or
        // `PlayerView`'s video gesture, and closes the whole controls overlay
        // too.
        .overlay {
            if isShowingTrackPicker {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if isShowingTrackPicker {
                trackPickerContent
                    // Clearance for the top button row: its height plus
                    // `topSection`'s 16pt padding above and below. Derived from
                    // `topControlSize` rather than a literal, which holds only
                    // at the default text size — at AX3XL the grown row pushes
                    // through the panel's top edge.
                    .padding(.top, topControlSize + 32)
                    .padding(.trailing, 20)
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        // The chapter picker's catcher and panel, mounted after the track
        // picker's so they sit above it. The two are never open at once —
        // opening either is a tap that dismisses the other — so the ordering is
        // defensive.
        .overlay {
            if isShowingChapterPicker {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(ChapterPickerOverlay.animation) { isShowingChapterPicker = false }
                    }
            }
        }
        // Anchored bottom-leading under the current-chapter button that opens
        // it, rather than top-trailing like the track picker. The bottom padding
        // clears the scrubber row and that button — approximate, like the track
        // picker's, not measured. Smaller in landscape, matching
        // `ChapterPickerOverlay.maxHeight`'s reduced cap.
        .overlay(alignment: .bottomLeading) {
            if isShowingChapterPicker {
                ChapterPickerOverlay(
                    chapters: viewModel.chapters,
                    currentChapter: viewModel.currentChapter,
                    onSelect: { chapter in
                        onInteract()
                        viewModel.seek(to: chapter.startSeconds)
                        withAnimation(ChapterPickerOverlay.animation) { isShowingChapterPicker = false }
                    }
                )
                .padding(.bottom, isLandscape ? 56 : 96)
                .padding(.leading, 20)
                .transition(.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        // No container identifier: this overlay is inside the same
        // `.fullScreenCover`, so one on its root propagates down and overwrites
        // every control's own.
    }

    /// `topSection`, `transportControls` and `scrubberBar` stacked, separate from
    /// `body` so the blank-space tap catcher can sit behind them as a `ZStack`
    /// sibling. Carries no `.background()` of its own (see `backgroundGradient`),
    /// so it is purely interactive content: a tap on a `Spacer()` gap falls
    /// through to the catcher behind.
    private var content: some View {
        VStack {
            topSection

            VStack {
                Spacer()
                transportControls
                Spacer()
            }

            scrubberBar
        }
    }

    /// The corner-anchored logo gradient and bottom darkening, as `body`'s
    /// backmost `ZStack` sibling rather than a `.background()` on `content`.
    /// These are real gradient pixels, and a `.background()`'s drawn content
    /// occludes hit-testing behind it, which silently blocked the blank-space
    /// catcher across the whole overlay. Backmost, it can occlude nothing.
    private var backgroundGradient: some View {
        ZStack {
            // Corner-anchored, sitting mainly under the logo. The flat plateau
            // out to 45% of the radius is deliberate: `.topLeading` is the
            // screen's true corner, since this ignores the safe area, and sits
            // above and left of the logo's safe-area-respecting position. A
            // 2-stop fade was already dim by the time it reached there,
            // undershooting the area this covers. Holding near-full opacity past
            // the logo before tapering still reaches `.clear` inside endRadius.
            //
            // Stretched wider than tall: a wordmark is much wider than high, so
            // a circular `RadialGradient` left its right half on unfaded video
            // before the falloff caught up. Scaling from `.topLeading` fixes the
            // anchor corner and reaches proportionally further right than down.
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

            // Bottom-only: the scrubber's legibility comes from
            // `scrubberTrack`'s explicit colors, not from darkening behind it.
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Without this the gradient is sized to this view's safe-area-respecting
        // frame rather than the screen, falling short of the physical edges —
        // most visible in landscape, where the inset is on the corner side this
        // is meant to bleed into. Only this decorative layer ignores the safe
        // area; the controls still avoid the sensor housing and home indicator.
        .ignoresSafeArea()
        // Decorative, so excluded from hit-testing alongside sitting behind the
        // catcher above.
        .allowsHitTesting(false)
    }

    /// Close and track-selection buttons plus the logo row. The corner-anchored
    /// gradient behind them lives on the whole overlay's background rather than
    /// this section's `VStack`: `.background()` clips to the view it is attached
    /// to, and this section is only as tall as its content — well under the
    /// gradient's 320pt radius — so the fade was cut off mid-way, visible as a
    /// hard line under the logo.
    private var topSection: some View {
        VStack {
            HStack {
                // A close button, not a minimize: `onClose` always stops playback
                // and reports a resume point, never leaving the session running,
                // so the icon should read as exit rather than tuck away.
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        // `.system(size:)` rather than `.title2`: identical at
                        // the default text size, but clamped at the top of the
                        // Dynamic Type range so the row can't outgrow its width.
                        .font(.system(size: topGlyphSize))
                        // Pads the glyph to HIG's 44×44 minimum. Once blank space
                        // is tappable-to-dismiss, a control with a small hit area
                        // is easy to narrowly miss and misfire a dismiss.
                        .frame(width: topControlSize, height: topControlSize)
                        .contentShape(Rectangle())
                }
                // No explicit label: the system names an "xmark" glyph "Close".
                // The identifier is the stable handle a test uses.
                .accessibilityIdentifier(A11yID.Player.closeButton)

                Spacer()

                // Its own spacing rather than the outer `HStack`'s, matching the
                // touch-target spacing `transportControls` uses.
                HStack(spacing: 20) {
                    // Omitted where the system won't act on the lock at all (see
                    // `RotationLock.isSupported`, false on a multitasking iPad),
                    // rather than shown disabled like the PiP and stats buttons:
                    // a button that toggles its icon and does nothing reads as
                    // broken rather than unavailable.
                    if RotationLock.isSupported {
                        Button {
                            onInteract()
                            onToggleRotationLock()
                        } label: {
                            // The padlock swap alone is too subtle against a busy
                            // video frame, so locked also gets a solid white
                            // badge with the glyph flipped to black — the
                            // on-state affordance a Control Center toggle uses.
                            // Unlocked stays a plain icon like the rest of the
                            // row.
                            Image(systemName: isRotationLocked ? "lock.rotation" : "lock.rotation.open")
                                .font(.system(size: topGlyphSize))
                                .foregroundStyle(isRotationLocked ? .black : .white)
                                .frame(width: topBadgeSize, height: topBadgeSize)
                                .background {
                                    if isRotationLocked {
                                        Circle().fill(Color.white)
                                    }
                                }
                                // The badge stays smaller than the tap target: an
                                // outer frame it centres in carries the ≥44pt.
                                .frame(width: topControlSize, height: topControlSize)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(isRotationLocked ? Text("Unlock rotation") : Text("Lock rotation"))
                        .accessibilityIdentifier(A11yID.Player.rotationLockButton)
                        .animation(.easeInOut(duration: 0.15), value: isRotationLocked)
                    }

                    trackSelectionButton

                    // Omitted rather than disabled: PiP is unavailable only on
                    // AetherEngine's software route, or before AVKit reports the
                    // layer ready, and neither warrants an inert button.
                    if viewModel.isPictureInPicturePossible {
                        Button {
                            onInteract()
                            onEnterPictureInPicture()
                        } label: {
                            Image(systemName: "pip.enter")
                                .font(.system(size: topGlyphSize))
                                .frame(width: topControlSize, height: topControlSize)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Picture in Picture"))
                        .accessibilityIdentifier(A11yID.Player.pictureInPictureButton)
                    }

                    // Same active/on-state badge treatment as the rotation
                    // lock button above — a plain glyph swap alone proved
                    // too subtle against a busy video frame for that one
                    // (see its own comment), and this is the same kind of
                    // persistent-until-toggled-again state.
                    //
                    // Gated on the Advanced settings toggle
                    // (`isPlaybackStatsButtonEnabled`) — omitted entirely
                    // when disabled, not shown-disabled, same treatment the
                    // PiP button above gets when unavailable.
                    if isPlaybackStatsButtonEnabled {
                        Button {
                            onInteract()
                            onTogglePlaybackStats()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: topGlyphSize))
                                .foregroundStyle(isPlaybackStatsVisible ? .black : .white)
                                .frame(width: topBadgeSize, height: topBadgeSize)
                                .background {
                                    if isPlaybackStatsVisible {
                                        Circle().fill(Color.white)
                                    }
                                }
                                // Same badge-inside-a-larger-tap-target
                                // treatment as the rotation lock button
                                // above, scaled the same way.
                                .frame(width: topControlSize, height: topControlSize)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(isPlaybackStatsVisible ? Text("Hide playback stats") : Text("Show playback stats"))
                        .accessibilityIdentifier(A11yID.Player.statsButton)
                        .animation(.easeInOut(duration: 0.15), value: isPlaybackStatsVisible)
                    }

                    // Landscape-only, keyed off `isLandscapeWindow` rather than
                    // the `isLandscape` size class the rest of this file uses:
                    // `verticalSizeClass == .compact` is iPhone's landscape
                    // signal and stays `.regular` on iPad in both orientations,
                    // so gating on it left iPad with no zoom affordance at all —
                    // not this button, nor the double-tap or pinch sharing the
                    // gate. 2.40:1 content in iPad portrait then rendered 349pt
                    // tall inside an 1180pt screen with no way to fill it.
                    //
                    // Window shape rather than `interfaceOrientation`: it is the
                    // app's established pattern, re-evaluates on its own, can't
                    // be fooled by this screen's rotation lock, and in Split View
                    // describes the window the video is in.
                    //
                    // No on-state badge, unlike rotation lock and stats: the
                    // glyph already swaps direction to show which state a tap
                    // leads to.
                    if isLandscapeWindow {
                        Button {
                            onInteract()
                            onToggleZoomMode()
                        } label: {
                            Image(systemName: zoomMode == .fill
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: topGlyphSize))
                                .frame(width: topControlSize, height: topControlSize)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(
                            zoomMode == .fill
                                ? String(localized: "Zoom to Fit Screen")
                                : String(localized: "Zoom to Fill Screen")
                        )
                    }
                }
            }
            .foregroundStyle(.white)
            // These sit outside `backgroundGradient`'s corner ellipse, which is
            // down to ~9% opacity at the trailing edge, so in landscape — where
            // video reaches the top of the screen — they are white on unmodified
            // video. See `controlScrim`.
            .modifier(controlScrim)
            .padding()

            titleRow
        }
    }

    /// Which picker page is showing: `.root` when both categories offer a
    /// choice, else the one applicable leaf — `trackSelectionButton` skips a
    /// root page with a single row. Reset each time the picker opens, so it
    /// never reopens mid-drill-down.
    private enum TrackPickerPage: Equatable {
        case root
        case audio
        case subtitle
    }

    @State private var trackPickerPage: TrackPickerPage = .root

    /// A leaf page's identity, narrower than `TrackPickerPage` and its `.root`
    /// case. `displayedLeafPage` is never root, and this makes that structural
    /// rather than an unreachable `switch` case taken on trust.
    private enum TrackPickerLeaf {
        case audio
        case subtitle

        var page: TrackPickerPage {
            switch self {
            case .audio: return .audio
            case .subtitle: return .subtitle
            }
        }
    }

    /// Which leaf page's content is built, independent of `trackPickerPage` (see
    /// `leafPage`).
    @State private var displayedLeafPage: TrackPickerLeaf = .audio

    /// The panel's height, driving `trackPickerContent`'s `.frame(height:)`. A
    /// plain `@State` rather than a value computed from `trackPickerPage` in the
    /// body, so it is an ordinary animatable property with no `.transition` or
    /// `.animation(_:value:)` nearby to interact with.
    @State private var trackPickerHeight: CGFloat = 0

    /// The only place that changes `trackPickerPage` after the initial open;
    /// `trackSelectionButton` sets the first page directly, with nothing on
    /// screen to animate.
    ///
    /// `displayedLeafPage` updates first, outside the animated block and only for
    /// a real leaf: going back to `.root` leaves the last leaf in place so it has
    /// content to slide away with rather than going blank mid-exit.
    /// `trackPickerHeight` and `trackPickerPage` then change inside one
    /// `withAnimation`, so the resize and the slide play as a single motion, the
    /// way a `UINavigationController` push slides the page and resizes its nav
    /// bar together.
    private func navigateToTrackPickerPage(_ page: TrackPickerPage) {
        switch page {
        case .audio: displayedLeafPage = .audio
        case .subtitle: displayedLeafPage = .subtitle
        case .root: break
        }
        withAnimation(Self.trackPickerNavigationAnimation) {
            trackPickerPage = page
            trackPickerHeight = min(estimatedHeight(for: page), Self.trackPickerMaxHeight)
        }
    }

    private var hasAudioChoice: Bool { viewModel.audioTracks.count > 1 }
    private var hasSubtitleChoice: Bool { !viewModel.subtitleTracks.isEmpty }

    /// Audio and subtitle track picker: a compact panel rather than a full
    /// sheet, for a small in-place choice.
    ///
    /// The root page's rows appear only where there is a choice —
    /// `hasAudioChoice` needs more than one audio track, `hasSubtitleChoice` at
    /// least one subtitle track. With only one applicable, the tap handler opens
    /// straight into that leaf; with neither, the button disables itself rather
    /// than opening an empty picker.
    ///
    /// Hand-rolled overlay content rather than a `Menu`, a `List` in a
    /// `.popover`, or a bare `.popover`. A `Menu`'s width and font are
    /// system-controlled, wrapping long commentary titles across several cramped
    /// lines. A `List` fixes the sizing but brings a translucent system
    /// background that reads poorly. A `.popover` with an explicit
    /// `.presentationBackground` fixes that, but `UIPopoverBackgroundView`'s
    /// chrome keeps its light fill independently, so the chrome and this view's
    /// dark content animate as two layers slightly out of step. One
    /// `.overlay(alignment:)` layer has nothing to desync against.
    @ViewBuilder
    private var trackSelectionButton: some View {
        let hasAnyChoice = hasAudioChoice || hasSubtitleChoice

        Button {
            onInteract()
            if hasAudioChoice && hasSubtitleChoice {
                trackPickerPage = .root
            } else if hasAudioChoice {
                trackPickerPage = .audio
                displayedLeafPage = .audio
            } else {
                trackPickerPage = .subtitle
                displayedLeafPage = .subtitle
            }
            // Set directly, not via `navigateToTrackPickerPage`: this is the
            // first page, appearing with the panel's own open transition rather
            // than a drill-down with anything to slide.
            trackPickerHeight = min(estimatedHeight(for: trackPickerPage), Self.trackPickerMaxHeight)
            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = true }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: topGlyphSize))
                // The dimmed unavailable state is exempt from the contrast
                // floor, but someone with Increase Contrast on still needs the
                // difference between dim and gone to be readable.
                .opacity(hasAnyChoice ? 1 : (isIncreasedContrast ? 0.6 : 0.4))
                .frame(width: topControlSize, height: topControlSize)
                .contentShape(Rectangle())
        }
        .disabled(!hasAnyChoice)
        .accessibilityIdentifier(A11yID.Player.tracksButton)
    }

    /// A synchronous estimate of a page's content height, not a measurement.
    /// **Don't replace it with one:** both `GeometryReader`+`PreferenceKey`
    /// approaches — measuring the visible `ScrollView`, then a hidden
    /// `.fixedSize` copy — left the panel at zero size in this
    /// conditionally-mounted, animated, `.overlay`-nested context. Row counts are
    /// known synchronously, so arithmetic has no stuck-at-zero failure mode.
    ///
    /// The cost is precision: a title wrapping to two lines makes its row taller
    /// than estimated, which is extra scroll headroom in a view that scrolls.
    private func estimatedHeight(for page: TrackPickerPage) -> CGFloat {
        // Root's rows are taller than a leaf's: each carries a title and a
        // current-selection subtitle where a leaf row is normally one line. A
        // leaf also adds its header, since header and rows slide as one unit.
        switch page {
        case .root:
            return navigationRowHeight * 2 + Self.dividerHeight
        case .audio:
            let count = viewModel.audioTracks.count
            let rows = selectionRowHeight * CGFloat(count) + Self.dividerHeight * CGFloat(max(0, count - 1))
            return leafHeaderHeight + Self.dividerHeight + rows
        case .subtitle:
            // +1 for "Off", which isn't in `subtitleTracks`.
            let count = viewModel.subtitleTracks.count + 1
            let rows = selectionRowHeight * CGFloat(count) + Self.dividerHeight * CGFloat(max(0, count - 1))
            return leafHeaderHeight + Self.dividerHeight + rows
        }
    }

    /// `navigationRow`'s two-line rows: 10pt vertical padding either side plus a
    /// `.subheadline` and a `.footnote` line with 2pt spacing.
    ///
    /// `@ScaledMetric`, like the two below: `estimatedHeight(for:)` sizes the
    /// panel from these and the rows grow with Dynamic Type, so fixed points
    /// drift. At AX3XL a root row renders 133.5pt against a fixed 56, sizing the
    /// panel at 113pt, clipping the first row mid-word and pushing "Subtitles"
    /// outside the panel.
    @ScaledMetric(relativeTo: .subheadline) private var navigationRowHeight: CGFloat = 56
    /// `selectionRow`'s rows: 10pt vertical padding either side plus a
    /// `.subheadline` title and, for most tracks, a `.footnote` metadata line.
    /// Sized for that common two-line case; a track with no flags renders a line
    /// shorter, the same acceptable gap as a wrapped title.
    @ScaledMetric(relativeTo: .subheadline) private var selectionRowHeight: CGFloat = 56
    /// `backRow`/`leafTitleRow`: 12pt vertical padding either side plus one
    /// `.subheadline` line.
    @ScaledMetric(relativeTo: .subheadline) private var leafHeaderHeight: CGFloat = 44
    /// Fixed, unlike the three above: a hairline rule, not text.
    private static let dividerHeight: CGFloat = 1

    /// The root page's "Audio"/"Subtitles" navigation rows. Always mounted at a
    /// fixed height regardless of `trackPickerPage`, as a base layer rather than
    /// one case of a swapping `switch` — see `trackPickerContent`.
    private var rootPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                navigationRow(
                    systemImage: "waveform", title: String(localized: "Audio"), value: currentAudioTrackTitle,
                    identifier: A11yID.Player.trackNavigationRow("audio")
                ) { navigateToTrackPickerPage(.audio) }
                divider
                navigationRow(
                    systemImage: "captions.bubble", title: String(localized: "Subtitles"), value: currentSubtitleTrackTitle,
                    identifier: A11yID.Player.trackNavigationRow("subtitle")
                ) { navigateToTrackPickerPage(.subtitle) }
            }
        }
        .frame(height: estimatedHeight(for: .root))
    }

    /// Slides `leafPage` clear of the panel when parked off-screen. Larger than
    /// `trackPickerMaxWidth`, so it is outside whichever width between ideal and
    /// max is used.
    private static let trackPickerSlideOffset: CGFloat = 400

    /// A leaf page for whichever page `displayedLeafPage` names — not
    /// `trackPickerPage` — always mounted rather than conditionally (see
    /// `trackPickerContent`). Its header is stacked inside this view so header
    /// and list slide as one unit; an independently cross-fading header was part
    /// of what made this read as a fade.
    private var leafPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasAudioChoice && hasSubtitleChoice {
                backRow(for: displayedLeafPage)
            } else {
                leafTitleRow(for: displayedLeafPage)
            }
            divider

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch displayedLeafPage {
                    case .audio:
                        trackRows(viewModel.audioTracks, kind: "audio") { track in
                            onInteract()
                            viewModel.selectAudioTrack(id: track.id)
                            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                        }

                    case .subtitle:
                        selectionRow(
                            title: String(localized: "Off"),
                            metadata: nil,
                            isSelected: !viewModel.subtitleTracks.contains { $0.isSelected },
                            identifier: A11yID.Player.subtitleOffOption
                        ) {
                            onInteract()
                            viewModel.selectSubtitleTrack(id: nil)
                            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                        }
                        if !viewModel.subtitleTracks.isEmpty { divider }
                        trackRows(viewModel.subtitleTracks, kind: "subtitle") { track in
                            onInteract()
                            viewModel.selectSubtitleTrack(id: track.id)
                            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                        }
                    }
                }
            }
        }
        .frame(height: min(estimatedHeight(for: displayedLeafPage.page), Self.trackPickerMaxHeight))
        // Opaque, matching the panel's fill: otherwise both this leaf and
        // `rootPage` are transparent apart from their text, and root's rows show
        // through wherever this leaf's don't cover the same pixels mid-slide.
        .background(Color(white: 0.1))
    }

    /// `rootPage` as a permanent base layer with `leafPage` always mounted above
    /// it, pushed to `trackPickerSlideOffset` and clipped by the panel's bounds
    /// while `trackPickerPage == .root`, animated back to `0` otherwise.
    ///
    /// Plain `.offset(x:)` rather than `.transition`: `.id()` plus `.transition`
    /// animates outgoing and incoming as a matched pair with no way to hold one
    /// still, reading as a cross-dissolve, and a conditionally-mounted leaf needs
    /// `.animation(nil, value:)` on the container to stop its height animating,
    /// which cascades as the ambient transaction and kills the leaf's own
    /// transition. `.offset` has no insert/remove pairing and nothing to cascade.
    ///
    /// `trackPickerHeight` changes in the same `withAnimation` as
    /// `trackPickerPage`, so the resize and slide play as one motion.
    @ViewBuilder
    private var trackPickerContent: some View {
        ZStack(alignment: .topLeading) {
            rootPage

            leafPage
                .offset(x: trackPickerPage == .root ? Self.trackPickerSlideOffset : 0)
                // Alongside the panel's `.clipped()` below: without this the
                // parked-off-screen leaf still intercepts taps meant for
                // `rootPage`.
                .allowsHitTesting(trackPickerPage != .root)
        }
        .frame(idealWidth: Self.trackPickerIdealWidth, maxWidth: Self.trackPickerMaxWidth)
        .frame(height: trackPickerHeight, alignment: .top)
        .clipped()
        .foregroundStyle(.white)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    private func backRow(for page: TrackPickerLeaf) -> some View {
        Button {
            navigateToTrackPickerPage(.root)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text(page == .audio ? String(localized: "Audio") : String(localized: "Subtitles"))
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.ignore`, not `.combine`: the leading chevron is decorative
        // wayfinding, and "Back" already conveys what the button does.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Back"))
    }

    private func leafTitleRow(for page: TrackPickerLeaf) -> some View {
        Text(page == .audio ? String(localized: "Audio") : String(localized: "Subtitles"))
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    /// A root-page row that drills into a leaf rather than selecting anything.
    /// Its trailing chevron, against a leaf row's checkmark, signals that, and
    /// `value` previews the leaf's current selection without the extra tap. The
    /// leading icon gives both rows a native Settings row's shape;
    /// `"captions.bubble"` is shared with `trackSelectionButton` as Apple's
    /// canonical subtitles glyph.
    private func navigationRow(
        systemImage: String, title: String, value: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline)
                    Text(value)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.ignore`: the icon and chevron are decorative, and `value` is folded
        // into the label, there being no `.accessibilityValue` reader for a row
        // that navigates rather than adjusts in place.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(title), \(value)"))
        .accessibilityIdentifier(identifier)
    }

    /// A leaf page's track list, with dividers between entries but not after the
    /// last — the separator `List` would draw, hand-rolled since this view
    /// doesn't use `List`. `kind` feeds `A11yID.Player.trackOption(_:_:)`, the
    /// same string `rootPage`'s navigation row uses.
    @ViewBuilder
    private func trackRows(_ tracks: [PlaybackTrack], kind: String, onSelect: @escaping (PlaybackTrack) -> Void) -> some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            if index > 0 { divider }
            selectionRow(
                title: track.title, metadata: track.metadata, isSelected: track.isSelected,
                identifier: A11yID.Player.trackOption(kind, track.id)
            ) {
                onSelect(track)
            }
        }
    }

    /// `metadata` renders as a `.footnote` line under `title` when present —
    /// `navigationRow`'s shape with a leading checkmark instead of a trailing
    /// chevron. `nil` collapses to one line rather than leaving a gap.
    private func selectionRow(title: String, metadata: String?, isSelected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                // `.opacity` rather than an `if`, reserving the checkmark's width
                // so titles don't shift as selection moves between rows.
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                    if let metadata {
                        Text(metadata)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.ignore` — the checkmark is purely visual state (`.opacity`, not
        // an `if`, so it's always present in the tree either way); the
        // *actual* selected state a VoiceOver user needs is exposed via
        // `.isSelected` below instead, not left to a shape/opacity a screen
        // reader can't perceive at all.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metadata.map { String(localized: "\(title), \($0)") } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var divider: some View {
        Divider().overlay(Color.white.opacity(0.15))
    }

    private var currentAudioTrackTitle: String {
        viewModel.audioTracks.first(where: \.isSelected)?.title ?? String(localized: "Default")
    }

    private var currentSubtitleTrackTitle: String {
        viewModel.subtitleTracks.first(where: \.isSelected)?.title ?? String(localized: "Off")
    }

    /// The rewind/play-pause/forward row — swapped for a centered spinner
    /// while `isBuffering`, rather than leaving the play/pause button
    /// showing a state that isn't actually available yet (tapping play
    /// mid-buffer did nothing perceptible, which read as broken rather than
    /// "in progress"). Covers `.idle` (still fetching the item/playback
    /// info/stream URL over the network — `PlayerViewModel.state` stays
    /// `.idle` for that entire window, since nothing updates it until
    /// `engine.load(url:)` is actually reached; without this the transport
    /// row showed a plain, tappable-looking Play button with no indication
    /// anything was happening — confirmed live, 2026-08-24, most visibly
    /// while offline, where that window can run long enough to be mistaken
    /// for a dead screen), the initial buffer on load/resume (`.loading`),
    /// an in-progress scrub (`.seeking`), an ordinary mid-playback rebuffer
    /// (`.buffering`), and a dropped/retrying source connection
    /// (`.reconnecting` — labeled distinctly below, rather than reading as
    /// an unexplained generic stall).
    @ViewBuilder
    private var transportControls: some View {
        if isBuffering {
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.6)
                if viewModel.state == .reconnecting {
                    Text("Reconnecting…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(secondaryTextOpacity))
                }
            }
            // Matches the play/pause button's own footprint, so nothing
            // else in the layout shifts when this swaps in and out.
            .frame(height: transportSize)
        } else {
            HStack(spacing: 40) {
                Button {
                    onInteract()
                    viewModel.seek(to: max(0, displayedTime - 15))
                } label: {
                    Image(systemName: "gobackward.15")
                        // `.system(size: skipGlyphSize)` rather than
                        // `.title` — identical at the default text size
                        // (Title 1 *is* 28pt) but scaled in lockstep with
                        // the play/pause glyph and with the frame below, so
                        // the skip buttons can neither overtake the primary
                        // control nor outgrow their own tap target. See
                        // `transportSize`.
                        .font(.system(size: skipGlyphSize))
                        // Same HIG-44pt tap-target padding as every other
                        // icon button in this overlay — see the close
                        // button's doc comment in `topSection`.
                        .frame(width: transportSize, height: transportSize)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Rewind 15 Seconds"))
                .accessibilityIdentifier(A11yID.Player.skipBackwardButton)

                Button {
                    onInteract()
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: playGlyphSize))
                        .frame(width: transportSize, height: transportSize)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(viewModel.state == .playing ? String(localized: "Pause") : String(localized: "Play"))
                .accessibilityIdentifier(A11yID.Player.playPauseButton)

                Button {
                    onInteract()
                    viewModel.seek(to: min(viewModel.duration, displayedTime + 30))
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: skipGlyphSize))
                        .frame(width: transportSize, height: transportSize)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Fast Forward 30 Seconds"))
                .accessibilityIdentifier(A11yID.Player.skipForwardButton)
            }
            .foregroundStyle(.white)
            // The middle of the screen is the one region `backgroundGradient`
            // covers neither end of, so these three sit on raw video. This
            // is where the contrast measurement was worst — see
            // `controlScrim`.
            .modifier(controlScrim)
        }
    }

    private var isBuffering: Bool {
        viewModel.state == .idle || viewModel.state == .loading || viewModel.state == .seeking
            || viewModel.state == .buffering || viewModel.state == .reconnecting
    }

    /// Logo preferred, pinned top-left — the same "logo over text-title
    /// fallback" convention `BackdropLogoOverlay` uses on the detail pages.
    /// Falls back to the plain title text when the item has no logo image at
    /// all, or when `LogoImageView` fails to load the one it has (a 404, a
    /// timeout after retries — see that type's doc comment). Contrast
    /// against the video behind it comes from the overlay's own background
    /// gradient (see `topSection`'s doc comment), not from anything owned
    /// here.
    ///
    /// `viewModel.offlineLogoURL ?? item.logoImageURL`: for a downloaded
    /// item `item.logoImageURL` is always `nil` (its synthetic `BaseItemDto`
    /// carries no `imageTags` — see `PlayerViewModel.startOffline`'s doc
    /// comment), so the offline logo travels separately as a local file URL
    /// instead. Same `isFileURL` branch to `LocalFileImage` vs.
    /// `LogoImageView` that `BackdropLogoOverlay` uses, for the same reason:
    /// a local read is synchronous and already cached, so there's no load
    /// latency for `LogoImageView`'s fade-in to hide.
    ///
    /// For episodes, an "S1:E4 · Episode Name" line (`MediaItem.railSubtitle`
    /// — falls back to just the episode name if the numbering isn't present)
    /// always appears below whatever's on the first line, so the episode
    /// itself stays identifiable even when the logo/title above it only
    /// names the show. What's on that first line still follows the
    /// logo-preferred rule above: the show's logo when there is one, or —
    /// only for episodes, since a movie/series' own title already *is* the
    /// name that would go here — the show's plain title text when there
    /// isn't.
    @ViewBuilder
    private var titleRow: some View {
        if let item = viewModel.item {
            ZStack(alignment: .topLeading) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let logoURL = viewModel.offlineLogoURL ?? item.logoImageURL {
                            if logoURL.isFileURL {
                                LocalFileImage(url: logoURL, contentMode: .fit)
                                    .frame(maxWidth: 240, maxHeight: 60, alignment: .leading)
                            } else {
                                #if DEBUG
                                LogoImageView(
                                    url: logoURL, fallback: titleText(item.railTitle),
                                    onFallbackVisibilityChange: { isLogoFallbackVisible = $0 }
                                )
                                .frame(maxWidth: 240, maxHeight: 60, alignment: .leading)
                                #else
                                LogoImageView(url: logoURL, fallback: titleText(item.railTitle))
                                    .frame(maxWidth: 240, maxHeight: 60, alignment: .leading)
                                #endif
                            }
                        } else if item.kind == .episode {
                            titleText(item.railTitle)
                        } else {
                            titleText(item.name)
                        }

                        if item.kind == .episode, let episodeSubtitle = item.railSubtitle {
                            episodeSubtitleText(episodeSubtitle)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
                // Same `.ignore` + explicit-label shape `HeroRailView`'s card
                // and `ProfileView`'s account row already use. Necessary here
                // specifically because the logo *replaces* the title text when
                // one exists: `LogoImageView`/`LocalFileImage` render a bare
                // `Image` with no label of its own, so a VoiceOver user got no
                // name at all for what was playing — the one thing this row
                // exists to say. Caught by `AccessibilityAuditTests`
                // ("missing useful accessibility information" on an unlabeled
                // image). `accessibilityDescription` already composes the
                // title-plus-episode line this row shows visually.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.accessibilityDescription)

                #if DEBUG
                // Test-only — a sibling of the `.ignore`-collapsed `HStack`
                // above, not a descendant of it, so it isn't swallowed the
                // same way. See `A11yID.Media.heroLogoFallbackVisible`.
                if UITestConfiguration.isActive, isLogoFallbackVisible {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityIdentifier(A11yID.Media.heroLogoFallbackVisible)
                }
                #endif
            }
        }
    }

    private func titleText(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func episodeSubtitleText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(secondaryTextOpacity))
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
                    .foregroundStyle(.white.opacity(isIncreasedContrast ? 1 : 0.7))
            }

            // 16, not 8: the thumb is a 20pt circle straddling the track's
            // edge, so it overflows past the declared bounds at either
            // extreme and used to overlap the timestamps. Applied here
            // symmetrically rather than as one-sided padding on
            // `scrubberTrack`, so both ends keep equal spacing.
            HStack(spacing: 16) {
                // Both labels reserve space for the widest string
                // `formatTime`/`endTimeText` can ever produce (an invisible
                // `"-9:59:59"`/`"9:59:59"` reference inside a `ZStack`,
                // rather than a hardcoded point width, so this still tracks
                // Dynamic Type) — without this, crossing an hour/minute
                // digit-count boundary (e.g. the countdown ticking from
                // "-1:00:00" to "-59:59") changed each label's natural
                // width, which pushed `scrubberTrack`'s own bounds around
                // with it. Each label is aligned toward the scrubber (the
                // leading one trailing-aligned, the trailing one
                // leading-aligned) so its digits grow away from the track
                // rather than shifting it. Fixing the track's own width
                // this way is also what keeps `ScrubThumbnailPreview`'s
                // drag-to-x-offset math stable while scrubbing.
                ZStack(alignment: .trailing) {
                    Text("9:59:59").monospacedDigit().hidden()
                    Text(Self.formatTime(displayedTime)).monospacedDigit()
                }
                // Bare "1:23:45" reads as disconnected digits with no
                // indication of what they mean — confirmed live (VoiceOver,
                // real device) this needs a spoken-out "current position"
                // lead-in, not just the value. `.updatesFrequently` stops
                // VoiceOver from re-announcing this out loud on every one of
                // `displayedTime`'s ~10-times-a-second ticks while it's the
                // focused element — the standard trait for exactly this
                // (a live-updating clock/timer), not something to leave off.
                .accessibilityLabel(String(localized: "Current position: \(Self.spokenTime(displayedTime))"))
                .accessibilityIdentifier(A11yID.Player.elapsedLabel)
                .accessibilityAddTraits(.updatesFrequently)

                scrubberTrack

                Button {
                    showRemainingTime.toggle()
                } label: {
                    ZStack(alignment: .leading) {
                        Text("-9:59:59").monospacedDigit().hidden()
                        Text(endTimeText).monospacedDigit()
                    }
                    // Pads the drawn timestamp out to HIG's 44pt minimum
                    // — it measured 51×14.5pt, under even the 28pt floor.
                    // Has to go on the *label*: a button hit-tests where its
                    // label paints, so a frame outside the `Button` grows the
                    // layout and the measured accessibility frame while
                    // leaving the real target text-sized. Layout-neutral —
                    // `scrubberTrack` already makes this row 44pt tall.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(endTimeAccessibilityLabel)
                .accessibilityIdentifier(A11yID.Player.remainingLabel)
                .accessibilityHint(String(localized: "Double tap to toggle between remaining time and total duration"))
                .accessibilityAddTraits(.updatesFrequently)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(secondaryTextOpacity))

            // Only for content that actually has chapters — see
            // `MediaItem.chapters`, which already collapses Jellyfin's
            // single-dummy-chapter case to empty.
            if !viewModel.chapters.isEmpty {
                HStack {
                    chapterButton
                    Spacer()
                }
            }
        }
        .padding()
        // Fires once per transition into a new magnetically-snapped chapter
        // while dragging the scrubber — see `chapterSnapHapticTrigger`.
        // `.light`, matching the "a boundary just passed under your finger"
        // scale of the event rather than `DownloadButton`'s heavier default
        // `.impact` for a long-press committing to an action.
        .sensoryFeedback(.impact(weight: .light), trigger: chapterSnapHapticTrigger)
    }

    /// The current chapter's name as a button, opening `ChapterPickerOverlay`
    /// — the same "what am I looking at, and where else can I go" affordance
    /// a YouTube chapter title serves. Falls back to a plain "Chapters"
    /// label in the one case `currentChapter` can be `nil` with chapters
    /// present: a playhead sitting before the first chapter's own start
    /// (rare — Jellyfin's first chapter is normally at 00:00 — but possible
    /// for a file whose chapter track starts late).
    private var chapterButton: some View {
        Button {
            onInteract()
            withAnimation(ChapterPickerOverlay.animation) { isShowingChapterPicker = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet")
                    .font(.caption2)
                Text(viewModel.currentChapter?.name ?? String(localized: "Chapters"))
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.caption2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(isIncreasedContrast ? 0.32 : 0.15), in: Capsule())
            // Pads the drawn capsule out to HIG's 44pt minimum touch
            // target height — same reasoning as every other control in
            // this overlay (see the close button's doc comment): once
            // blank space is tappable-to-dismiss, a narrowly-missed
            // control misfires a dismiss instead.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // The current chapter is folded into the label rather than exposed
        // as a separate `.accessibilityValue` — this button *navigates* (it
        // opens a picker) rather than adjusting a value in place, the same
        // distinction `navigationRow` above draws for the track picker's
        // own root rows. An empty value string would otherwise read as a
        // stray pause whenever `currentChapter` is nil.
        .accessibilityLabel(
            viewModel.currentChapter.map { String(localized: "Chapters, currently \($0.name)") }
                ?? String(localized: "Chapters")
        )
        .accessibilityHint(String(localized: "Double tap to choose a chapter"))
        .accessibilityIdentifier(A11yID.Player.chaptersButton)
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
                    .fill(Color.white.opacity(isIncreasedContrast ? 0.6 : 0.35))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.white)
                    .frame(width: width * fraction, height: 4)

                // Chapter boundaries, drawn over both track segments and
                // under the thumb — purely additive to the drawing above.
                // Filtered on `startSeconds > 0` rather than by dropping
                // index 0: it's normally the first chapter that sits at
                // 0:00, but the thing actually worth skipping is a divider
                // at the track's own leading edge (which reads as a
                // rendering artifact, not a boundary) whichever chapter
                // happens to be there. Dark rather than a lighter white, so
                // it stays visible against the *filled* (solid white)
                // segment as well as the unfilled one. Gated on
                // `isChaptersInScrubberEnabled` — the current-chapter
                // button/picker stay available either way, only this visual
                // segmentation (and the magnetic snap below) are optional.
                if isChaptersInScrubberEnabled {
                    ForEach(viewModel.chapters.filter { $0.startSeconds > 0 }) { chapter in
                        Rectangle()
                            .fill(Color.black.opacity(0.5))
                            .frame(width: Self.chapterDividerWidth, height: 4)
                            .offset(x: chapterBoundaryX(for: chapter, width: width) - Self.chapterDividerWidth / 2)
                    }
                }

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
            // `.overlay`, not a 4th `ZStack` sibling above — a `ZStack`
            // sizes itself to its *largest* child (see the Capsules' own
            // doc comment just above for the same lesson learned the hard
            // way about the 20pt thumb), so the bubble's own much taller
            // natural size (~114pt: 90pt image + spacing + the timestamp
            // pill) was inflating this whole track's reported height even
            // though `.offset` only moves where it *renders* — confirmed
            // live (2026-08-17): the scrubber row visibly dropped every
            // time a drag started. An `.overlay` is layout-inert by
            // definition — its content can never affect the base view's
            // own reported size, however tall it is — so this is the
            // correct tool here, not just a workaround.
            .overlay(alignment: .leading) {
                // Gated on `isDraggingScrubber`, not `isScrubbing` — the
                // latter deliberately stays `true` past finger-lift while a
                // seek lands (see that property's own doc comment above),
                // which would otherwise leave a stale bubble hanging on
                // screen after the finger's already gone. Clamped so its
                // own 160pt width stays fully inside the track even when
                // dragging to either extreme — unlike the 20pt thumb above,
                // it would otherwise clip off-screen there.
                if isDraggingScrubber, viewModel.supportsScrubThumbnails {
                    ScrubThumbnailPreview(
                        image: scrubThumbnailImage,
                        timeText: Self.formatTime(scrubTime),
                        // Reads off `scrubTime` (already snapped, when a
                        // snap is active) rather than tracking
                        // `snappedChapterIndex` separately — the two agree
                        // by construction, and this also names the chapter
                        // while merely dragging *through* one.
                        chapterName: viewModel.chapters.chapter(at: scrubTime)?.name
                    )
                        .offset(
                            x: min(
                                max(width * fraction - ScrubThumbnailPreview.width / 2, 0),
                                width - ScrubThumbnailPreview.width
                            ),
                            // Clears both the thumb and a finger actually
                            // touching it — `.overlay(alignment: .leading)`
                            // keeps the same vertically-centered-on-the-
                            // track baseline the old `ZStack(alignment:
                            // .leading)` gave it, so this offset needs no
                            // change from what that vertical centering
                            // already required: roughly half the bubble's
                            // own height plus the thumb's half-height.
                            y: -90
                        )
                }
            }
            // The visible track is a thin 4pt line, but the drag target
            // spans this whole `GeometryReader` frame (see `.frame(height:
            // 44)` below) — matches a plain `Slider`'s actual tap target,
            // which is much taller than what it visually draws.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        // Every move resets `PlayerView`'s auto-hide
                        // countdown — without this, a long, slow drag could
                        // outlast the 3-second timer and have the controls
                        // (scrubber included, mid-touch) fade out from under
                        // the user's finger.
                        onInteract()
                        isDraggingScrubber = true
                        isScrubbing = true
                        // Magnetic snap — a *soft pull*, not a detent:
                        // within `chapterSnapRadius` of a boundary the
                        // displayed/seek time locks to that chapter's exact
                        // start, but the finger keeps driving the raw
                        // position with no added resistance, so leaving the
                        // zone resumes free scrubbing immediately. The test
                        // is in pixel space, not time, so the pull feels the
                        // same on a 20-minute episode and a 3-hour film
                        // (where an equivalent time radius would be either
                        // unusably tight or absurdly wide).
                        if let snapped = snappedChapter(forDragX: drag.location.x, width: width) {
                            scrubTime = snapped.chapter.startSeconds
                            if snappedChapterIndex != snapped.index {
                                snappedChapterIndex = snapped.index
                                chapterSnapHapticTrigger.toggle()
                            }
                        } else {
                            let newFraction = min(1, max(0, drag.location.x / width))
                            scrubTime = newFraction * viewModel.duration
                            // Cleared without firing the haptic — a tick on
                            // the way *out* of a boundary would double every
                            // pass-through into a buzz-buzz.
                            snappedChapterIndex = nil
                        }
                        requestScrubThumbnail(at: scrubTime)
                    }
                    .onEnded { _ in
                        // So the next drag's first frame inside the same
                        // boundary counts as a fresh entry and ticks again.
                        snappedChapterIndex = nil
                        // `isScrubbing` deliberately stays `true` here — see
                        // the `onChange`s below for why, and `displayedTime`'s
                        // doc comment for what this keeps showing in the
                        // meantime.
                        onInteract()
                        isDraggingScrubber = false
                        scrubThumbnailTask?.cancel()
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
        .accessibilityIdentifier(A11yID.Player.scrubber)
        .accessibilityValue(Text(Self.formatTime(displayedTime)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: viewModel.seek(to: min(viewModel.duration, displayedTime + 15))
            case .decrement: viewModel.seek(to: max(0, displayedTime - 15))
            @unknown default: break
            }
        }
        // `viewModel.seek(to:)` is async — the engine reports its own
        // `.seeking` state and only pushes the new `currentTime` once the
        // seek actually lands, both some time after `onEnded` fires above.
        // Clearing `isScrubbing` synchronously in `onEnded` (the original
        // approach) made `displayedTime` fall back to `viewModel.currentTime`
        // immediately — still the *pre-seek* position for that gap — so the
        // thumb visibly snapped back to where playback had been before
        // jumping forward again once the real update arrived. Keeping
        // `isScrubbing` on through that gap keeps the thumb pinned exactly
        // where the user left it; these two `onChange`s are what eventually
        // let go of it again, once there's real evidence the seek landed
        // rather than on a fixed timer that could fire too early or too late.
        //
        // Two independent signals, either sufficient on its own, since
        // neither is individually guaranteed: a very small seek might never
        // visibly enter `.seeking` before the matching time update arrives
        // (the state-based check would never fire), while a target that
        // lands exactly between two clock ticks could in principle skip past
        // the epsilon window given engine-side rounding (the time-based
        // check would never fire). `!isDraggingScrubber` on both guards
        // against a stray match landing mid-drag, before `onEnded` has even
        // issued the seek this is meant to be watching for.
        .onChange(of: viewModel.currentTime) { _, newTime in
            guard isScrubbing, !isDraggingScrubber else { return }
            if abs(newTime - scrubTime) < 1.0 {
                isScrubbing = false
            }
        }
        .onChange(of: viewModel.state) { oldState, newState in
            guard isScrubbing, !isDraggingScrubber else { return }
            if oldState == .seeking, newState != .seeking {
                isScrubbing = false
            }
        }
        // SwiftUI only auto-cancels a `.task { }`-modifier Task on
        // disappearance, not a plain `Task` stored in `@State` like
        // `scrubThumbnailTask` — without this, closing the player mid-drag
        // (before a throttled fetch has fired) would leave that fetch/crop
        // running to completion against a state box nobody can ever render
        // from again. Harmless (no crash), just wasted network/CPU work
        // with no observer left.
        .onDisappear {
            scrubThumbnailTask?.cancel()
        }
    }

    /// Chapter-boundary divider thickness on the scrubber track — thin
    /// enough to read as a tick mark rather than a second thumb, but not
    /// hairline, which disappears against the filled segment.
    private static let chapterDividerWidth: CGFloat = 1.5

    /// How close (in points along the track, **not** in seconds) a drag has
    /// to come to a chapter boundary before the magnetic snap engages.
    ///
    /// Pinned at exactly 6pt by interactive validation against a throwaway
    /// browser prototype of this scrubber, not derived from anything — the
    /// design's own first guess was 16-20pt and was rejected in favor of
    /// this after trying both by hand. Don't widen it without re-running
    /// that comparison; the whole point of a *soft* pull is that it stays
    /// unnoticeable until you're essentially on the boundary already.
    private static let chapterSnapRadius: CGFloat = 6

    /// Where a chapter's start sits along the track, in points. Clamped to
    /// `[0, 1]` before scaling so a chapter start beyond the reported
    /// duration (possible mid-load, before `duration` settles) can't draw a
    /// divider off the end of the track.
    private func chapterBoundaryX(for chapter: Chapter, width: CGFloat) -> CGFloat {
        guard viewModel.duration > 0 else { return 0 }
        return width * min(1, max(0, chapter.startSeconds / viewModel.duration))
    }

    /// The chapter whose boundary the drag is currently within
    /// `chapterSnapRadius` of, plus its index — `nil` when there's no
    /// chapter in range, no chapters at all, or no duration to place them
    /// against yet. The *nearest* one wins when two boundaries are both in
    /// range (chapter-dense content at a short runtime), so the snap can
    /// never flip between two candidates on jitter alone.
    ///
    /// `x` is clamped to the track before measuring, so dragging past either
    /// end doesn't drift out of the first/last chapter's snap zone.
    ///
    /// Returns `nil` unconditionally when `isChaptersInScrubberEnabled` is
    /// off — the single choke point for the setting on the drag side, so
    /// `.onChanged` doesn't need its own separate check: with snapping
    /// disabled this always reports "nothing to snap to" and the drag
    /// handler's existing `else` branch (plain, unsnapped scrubbing) runs
    /// exactly as it did before chapters existed.
    private func snappedChapter(forDragX x: CGFloat, width: CGFloat) -> (index: Int, chapter: Chapter)? {
        guard isChaptersInScrubberEnabled, viewModel.duration > 0, !viewModel.chapters.isEmpty else { return nil }
        let clampedX = min(max(x, 0), width)
        var best: (index: Int, chapter: Chapter, distance: CGFloat)?
        for (index, chapter) in viewModel.chapters.enumerated() {
            let distance = abs(chapterBoundaryX(for: chapter, width: width) - clampedX)
            guard distance <= Self.chapterSnapRadius else { continue }
            if best == nil || distance < best!.distance {
                best = (index, chapter, distance)
            }
        }
        guard let best else { return nil }
        return (best.index, best.chapter)
    }

    /// How often `requestScrubThumbnail(at:)` allows a fetch to actually
    /// fire during a continuous drag.
    private static let scrubThumbnailThrottleInterval: TimeInterval = 0.12

    /// Throttled scrub-thumbnail fetch, called from every `scrubberTrack`
    /// drag tick. Deliberately a *throttle*, not a debounce (the shape this
    /// replaced, matching `SearchViewModel`'s search-as-you-type debounce):
    /// a debounce only fires once input goes quiet, which for a scrubber
    /// drag means a sufficiently fast, sustained, continuous gesture could
    /// in principle never let it fire at all until the finger actually
    /// pauses. A throttle instead guarantees a fetch roughly every
    /// `scrubThumbnailThrottleInterval` throughout continuous movement:
    /// fires immediately if that long has already passed since the last
    /// fetch *started* (not since the last tick — this is wall-clock time
    /// via `lastScrubThumbnailFireDate`, unrelated to how often
    /// `.onChanged` itself fires), otherwise schedules exactly one trailing
    /// fetch for whenever the window is up. Every tick in between just
    /// updates `pendingScrubSeconds`, which that already-scheduled fetch
    /// reads when it actually runs — so a whole burst of ticks collapses
    /// into a single fetch at the drag's *latest* position, not a stale
    /// one from partway through the burst.
    ///
    /// No-ops when `supportsScrubThumbnails` is false, matching
    /// `scrubberTrack`'s own gate on rendering the bubble at all.
    private func requestScrubThumbnail(at seconds: TimeInterval) {
        guard viewModel.supportsScrubThumbnails else { return }
        pendingScrubSeconds = seconds
        guard scrubThumbnailTask == nil else { return }

        let elapsed = lastScrubThumbnailFireDate.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let delay = max(0, Self.scrubThumbnailThrottleInterval - elapsed)
        scrubThumbnailTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else {
                scrubThumbnailTask = nil
                return
            }
            lastScrubThumbnailFireDate = Date()
            let requested = pendingScrubSeconds ?? seconds
            let image = await viewModel.scrubThumbnail(atSeconds: requested)
            // `nil` means "not available yet", not "no thumbnail exists" —
            // see `TrickplayThumbnailProvider`'s doc comment — so only a
            // successful result overwrites what's already showing.
            if !Task.isCancelled, let image {
                scrubThumbnailImage = image
            }
            scrubThumbnailTask = nil
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

    /// `endTimeText`'s spoken-out counterpart — same "needs a context
    /// lead-in, not just digits" fix as `displayedTime`'s own label above,
    /// with the lead-in itself switching between the button's two states
    /// (remaining vs. total) rather than reading as the same phrase either
    /// way.
    private var endTimeAccessibilityLabel: String {
        guard showRemainingTime else {
            return String(localized: "Total duration: \(Self.spokenTime(viewModel.duration))")
        }
        return String(localized: "Remaining time: \(Self.spokenTime(max(0, viewModel.duration - displayedTime)))")
    }

    /// The scrub-in-progress position while `isScrubbing`, otherwise live
    /// playback position. `isScrubbing` now covers more than the drag touch
    /// itself — it stays on through the just-issued seek landing too (see
    /// `scrubberTrack`'s gesture/`onChange`s) — so this keeps reading
    /// `scrubTime` for that whole window, not just while a finger is down.
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

    /// `formatTime`'s spoken-out counterpart, e.g. "1 hour, 23 minutes, 45
    /// seconds" instead of "1:23:45" — used only inside an
    /// `.accessibilityLabel`, never on screen. Unlike a colon-separated
    /// clock (which VoiceOver reads as digits reasonably well), this is
    /// specifically for the two scrubber timestamps, which need a "current
    /// position"/"remaining time"/"total duration" lead-in VoiceOver users
    /// confirmed live they were missing — see `Design Guideline —
    /// Accessibility`: values need to be perceivable, not just present.
    private static func spokenTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return String(localized: "0 seconds") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        guard let result = formatter.string(from: time), !result.isEmpty else {
            return String(localized: "0 seconds")
        }
        return result
    }
}

/// A dark halo behind a white glyph, so it stays legible over whatever
/// video frame happens to be underneath it — see
/// `PlayerControlsOverlay.controlScrim`, which is the only thing that
/// builds one and carries the full reasoning and the measurements.
///
/// A `ViewModifier` rather than a plain `.shadow(...)` at each call site so
/// the two clusters that need it (the top button row and the transport row)
/// can't drift apart, and so the Increase Contrast branch lives in exactly
/// one place.
private struct ControlScrim: ViewModifier {
    let opacity: Double
    let radius: CGFloat

    /// Two stacked passes, not one. A single `.shadow` is a blur, so its
    /// effective alpha right at the glyph's edge — the only place that
    /// decides legibility — is far below the nominal opacity. Measured on a
    /// bright frame, one pass at 0.65/4 lifted the adjacent pixel from 198
    /// to 167 (2.41:1 against the white glyph), short of the 3:1 non-text
    /// floor, which needs ≤149. Compositing the same shadow twice roughly
    /// squares the transmission at the edge without widening the halo into
    /// something visible as a smudge.
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(opacity), radius: radius)
            .shadow(color: .black.opacity(opacity), radius: radius)
    }
}
