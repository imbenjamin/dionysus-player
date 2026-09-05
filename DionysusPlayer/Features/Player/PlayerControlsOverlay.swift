import CoreGraphics
import SwiftUI

/// Both this default and `ProfileView`'s own `@AppStorage` default must be
/// declared identically by hand — nothing enforces they stay in sync (same
/// discipline as `showPlaybackStatsButtonEnabledStorageKey`'s documented
/// gotcha, `PlaybackStatsOverlay.swift`).
let chaptersInScrubberEnabledStorageKey = "chaptersInScrubberEnabled"
/// Default `true` — chapters in the scrubber (boundary dividers + magnetic
/// snap) are opt-out, not opt-in, matching every other chapter-UI surface
/// in the app (the rail, the current-chapter button, the picker) being
/// unconditionally on whenever chapters exist. This is the one exception a
/// user can turn off, for anyone who finds the snap distracting while
/// scrubbing — not because chapters-in-general default to hidden.
let chaptersInScrubberEnabledDefault = true

struct PlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    /// Whether the audio/subtitle track picker (`trackSelectionButton`) is
    /// showing — a `@Binding`, not local `@State` like the picker's other
    /// state (`trackPickerPage`), because `PlayerView`'s auto-hide timer
    /// needs to know about it too: without this, the timer had no way to
    /// tell the picker was open and would fade the whole controls row out
    /// from under it a few seconds in, panel and all. See
    /// `PlayerView.scheduleAutoHide()`.
    @Binding var isShowingTrackPicker: Bool
    /// Whether the chapter picker (`ChapterPickerOverlay`) is showing — a
    /// `@Binding` for exactly the same reason `isShowingTrackPicker` above
    /// is: `PlayerView`'s auto-hide timer has to know a panel is open, or it
    /// fades the whole controls row out from under it. See
    /// `PlayerView.scheduleAutoHide()`.
    @Binding var isShowingChapterPicker: Bool
    var onClose: () -> Void
    /// Whether `RotationLock` currently has rotation locked. Plain state
    /// owned by `PlayerView`, not a `@Binding` — this button only ever
    /// reports a tap via `onToggleRotationLock`, the same "closure out,
    /// value in" shape `onClose` already uses, since (unlike the scrubber)
    /// there's no continuous in-overlay gesture that needs to write back to
    /// it directly.
    var isRotationLocked: Bool
    var onToggleRotationLock: () -> Void
    /// Whether `PlaybackStatsOverlay` is currently showing — same "plain
    /// state in, closure out" shape as `isRotationLocked`/
    /// `onToggleRotationLock` above, for the same reason: this button only
    /// ever reports a tap, `PlayerView` owns the actual toggle.
    var isPlaybackStatsVisible: Bool
    var onTogglePlaybackStats: () -> Void
    /// Same "plain state in, closure out" shape as `isRotationLocked`/
    /// `onToggleRotationLock` above. Originally added VoiceOver-only, to
    /// make reachable what was otherwise only a double-tap/pinch gesture on
    /// the video surface (`PlayerView.handleDoubleTap()`/
    /// `pinchZoomGesture`) — kept for everyone per direct feedback once it
    /// existed ("I like it as a control regardless of VoiceOver"). Still
    /// landscape-gated the same way those gestures already are (see
    /// `isLandscape` below) — zoom is a landscape-only affordance app-wide,
    /// not something this button should expand the scope of.
    var zoomMode: VideoZoomMode
    var onToggleZoomMode: () -> Void
    /// Whether the player's window is currently wider than it is tall,
    /// measured by `PlayerView` via `.onGeometryChange` and handed down as
    /// plain state — the same "value in, closure out" shape `zoomMode`
    /// itself uses just above.
    ///
    /// Distinct from this file's own `isLandscape` (`verticalSizeClass ==
    /// .compact`), which is still the right signal for the two places that
    /// really mean "is this window short" — the chapter picker's bottom
    /// padding here, and `ChapterPickerOverlay.maxHeight`. This one means
    /// "is this window landscape-shaped", which on iPad the size class
    /// cannot answer. See the zoom button in `topSection` for the full
    /// reasoning.
    var isLandscapeWindow: Bool
    /// A one-shot action, unlike the two toggle buttons above — there's no
    /// "currently in PiP" state to mirror here, `viewModel
    /// .isPictureInPicturePossible` alone decides whether the button is
    /// enabled at all, and once tapped there's nothing left for this overlay
    /// to reflect (the "Playing in Picture in Picture" placeholder lives in
    /// `PlayerView`, keyed off `viewModel.isPictureInPictureActive`).
    var onEnterPictureInPicture: () -> Void
    /// Called on every button tap and scrubber-drag tick — `PlayerView`
    /// uses this to reset its auto-hide countdown, so a button press or an
    /// in-progress drag doesn't get cut off by the fade mid-interaction. Not
    /// called from `onClose` (playback is ending) or the timestamp-toggle
    /// button (doesn't affect anything visible enough to warrant resetting
    /// the timer over).
    var onInteract: () -> Void
    /// A tap that landed on blank space within this overlay — not on any
    /// button/scrubber/picker — while the controls are visible. `PlayerView`
    /// hides them immediately (with the same fade `scheduleAutoHide()`'s
    /// timer uses) rather than making the user wait out the full auto-hide
    /// delay. See `body`'s own full-overlay blank-space tap catcher for why
    /// a plain tap gesture there is enough to only catch *blank* taps —
    /// actual buttons/the scrubber/the track picker's own backdrop all sit
    /// above it and claim their own taps first.
    var onDismissControls: () -> Void

    /// Whether the scrubber's trailing timestamp reads as a `-`-prefixed
    /// countdown to the end (the default) or the asset's total duration —
    /// flipped by tapping that timestamp. Local `@State`: nothing outside
    /// this overlay needs to know which mode is showing.
    @State private var showRemainingTime = true
    /// Whether the info-circle button below (which toggles
    /// `PlaybackStatsOverlay`) should be shown at all — a persisted
    /// setting (Profile → Playback → Advanced), read directly via its own
    /// `@AppStorage` rather than threaded down from `PlayerView`, same
    /// "the view that displays a persisted setting reads it directly"
    /// shape `HeroHeaderView`'s `hero3DDepthEnabled` already uses. Default
    /// must stay in lockstep with `AdvancedPlaybackSettingsView`'s own read
    /// of this key — see `showPlaybackStatsButtonEnabledDefault`'s doc
    /// comment (`PlaybackStatsOverlay.swift`).
    @AppStorage(showPlaybackStatsButtonEnabledStorageKey) private var isPlaybackStatsButtonEnabled = showPlaybackStatsButtonEnabledDefault

    /// Gates the zoom-mode button below — same check `PlayerView.isLandscape`
    /// uses, duplicated here rather than threaded through as a parameter —
    /// a plain `@Environment` read, no reason to route it through the same
    /// "closure out" plumbing the actual zoom *state* needs.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Whether the user has Increase Contrast on. Every colour in this
    /// overlay is a hardcoded white or white-at-an-opacity, so before this
    /// the whole player ignored the setting outright — on the one screen
    /// where a user with contrast difficulties is most likely to have it on,
    /// since white chrome sits directly on arbitrary video here. The
    /// unfilled scrubber segment measured exactly 3.00:1 against black (the
    /// non-text floor) and didn't move when the setting was enabled.
    ///
    /// Used below to raise the low-opacity values toward opaque and to
    /// deepen `controlScrim`'s shadow, rather than to swap in a different
    /// palette — there's no colour here to re-tint, only contrast to add.
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    private var isIncreasedContrast: Bool { colorSchemeContrast == .increased }

    /// Secondary text (timestamps, the episode subtitle) — `0.8` white
    /// normally, opaque under Increase Contrast.
    private var secondaryTextOpacity: Double { isIncreasedContrast ? 1 : 0.8 }

    /// A dark halo behind whichever white glyph it's applied to. The
    /// overlay's own `backgroundGradient` only covers the top-left corner
    /// (for the logo) and a bottom fade (for the scrubber); the transport
    /// cluster in the middle and the button cluster at the top trailing edge
    /// both sit on unmodified video. Sampled against a real bright frame,
    /// a pure-white glyph cleared 3:1 — HIG's non-text minimum — over only
    /// 16% of the area behind the transport row, median 2.23:1, with a floor
    /// of 1.00:1 where snow made the glyph literally invisible.
    ///
    /// A shadow rather than a plate or a material behind each button: it
    /// costs nothing visually on the dark frames that are already fine (a
    /// black halo on black reads as nothing at all) and only shows up where
    /// it's actually needed, so the chrome-free look of the controls
    /// survives. Note it buys *perceptual* separation via an edge rather
    /// than raising the glyph's own measured ratio against the backdrop —
    /// the honest ceiling for white-on-arbitrary-video short of an opaque
    /// plate under every control.
    private var controlScrim: some ViewModifier {
        ControlScrim(opacity: isIncreasedContrast ? 1 : 0.8,
                     radius: isIncreasedContrast ? 7 : 5)
    }

    /// Top-row control sizing — the button's tap target, the on-state badge
    /// behind the glyph, and the glyph itself, in the 44 : 36 : 22 ratio
    /// they've always had.
    ///
    /// All three scale together now. Only the glyph did before (via
    /// `.font(.title2)`), while the frame and badge were fixed points — so
    /// at AX3XL the glyph outgrew its 36pt badge and spilled out on all
    /// sides, reading as a rendering fault rather than an active state
    /// (confirmed on an iPad at AX3XL, rotation-lock and stats buttons
    /// both).
    ///
    /// Clamped, unlike the picker row heights: this row carries up to five
    /// buttons plus the close button, and unbounded growth overflows its
    /// width on a narrow phone long before it runs out of room on an iPad.
    /// The caps hold the same 44 : 36 : 22 ratio so the badge never loses
    /// its glyph again at the top of the range either.
    @ScaledMetric(relativeTo: .title2) private var scaledTopControlSize: CGFloat = 44
    private var topControlSize: CGFloat { min(scaledTopControlSize, 60) }
    @ScaledMetric(relativeTo: .title2) private var scaledTopBadgeSize: CGFloat = 36
    private var topBadgeSize: CGFloat { min(scaledTopBadgeSize, 49) }
    @ScaledMetric(relativeTo: .title2) private var scaledTopGlyphSize: CGFloat = 22
    private var topGlyphSize: CGFloat { min(scaledTopGlyphSize, 30) }

    /// Transport-row sizing, same shape as the top row above: tap target,
    /// skip glyph, play/pause glyph, in their existing 44 : 28 : 44 ratio.
    ///
    /// Scaling these *together* is the point. Before, the skip buttons used
    /// `.font(.title)` (which scales) and play/pause used
    /// `.font(.system(size: 44))` (which doesn't), so at AX3XL the skip
    /// glyphs rendered ~55pt across against play/pause's 44 — the secondary
    /// controls visibly larger than the primary one, with the whole visual
    /// hierarchy inverted. The frames were fixed at 44 too, so both skip
    /// glyphs simply overflowed their own tap targets.
    @ScaledMetric(relativeTo: .title) private var scaledTransportSize: CGFloat = 44
    private var transportSize: CGFloat { min(scaledTransportSize, 72) }
    @ScaledMetric(relativeTo: .title) private var scaledSkipGlyphSize: CGFloat = 28
    private var skipGlyphSize: CGFloat { min(scaledSkipGlyphSize, 46) }
    @ScaledMetric(relativeTo: .title) private var scaledPlayGlyphSize: CGFloat = 44
    private var playGlyphSize: CGFloat { min(scaledPlayGlyphSize, 72) }

    /// Whether the scrubber shows chapter boundary dividers and magnetically
    /// snaps to them — a persisted setting (Profile → Playback, "Chapters in
    /// Scrubber"), read directly via its own `@AppStorage` for the same
    /// "the view that displays it reads it directly" reason
    /// `isPlaybackStatsButtonEnabled` above does. Default `true` must stay
    /// in lockstep with `ProfileView`'s own read of this key — see
    /// `chaptersInScrubberEnabledDefault`'s doc comment just below.
    ///
    /// Deliberately does **not** gate the current-chapter button or
    /// `ChapterPickerOverlay` — per the setting's own description, those
    /// stay available regardless. Only the two behaviors this key is named
    /// for: the track's boundary dividers, and the magnetic snap (soft pull
    /// + haptic) in the drag handler below.
    @AppStorage(chaptersInScrubberEnabledStorageKey) private var isChaptersInScrubberEnabled = chaptersInScrubberEnabledDefault

    /// Whether a touch is actively down on the scrubber track, as opposed to
    /// `isScrubbing` (the binding), which now stays `true` a little longer —
    /// through the just-issued seek landing, not just through the drag
    /// itself. See `scrubberTrack`'s gesture and the `onChange`s below for
    /// why the two need to be separate. Local: nothing outside this overlay
    /// needs to know a touch is down specifically, only that scrubbing (in
    /// the broader sense) is in progress.
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
    /// Flipped (never read directly) on each transition *into* a new snapped
    /// chapter — `.sensoryFeedback(_:trigger:)` fires on each change of its
    /// trigger, not on a particular value, matching the convention
    /// `DownloadButton.advancedOptionsHapticTrigger` established. Not
    /// flipped on leaving a snap zone, and never on a repeat frame within
    /// one: a continuous drag through a boundary should tick exactly once,
    /// not buzz for as long as the finger lingers there.
    @State private var chapterSnapHapticTrigger = false

    /// A fixed cap on the track picker panel's height, *not* a measured
    /// half of the real screen height — every attempt to read the real
    /// screen height via `GeometryReader`/`PreferenceKey` (a `GeometryReader`
    /// as `body`'s root, then a `.background(GeometryReader{...})`
    /// measurement instead) ended with the panel rendering nowhere at all;
    /// the common factor across every failure was *some* `GeometryReader`/
    /// `PreferenceKey` still in play somewhere in this view, which is why
    /// `estimatedHeight(for:)` below is a plain arithmetic estimate rather
    /// than a measurement too. Landscape iPhones (this player's primary
    /// orientation) comfortably clear this fixed cap in practice.
    private static let trackPickerMaxHeight: CGFloat = 320
    /// The panel's own width — named alongside `trackPickerMaxHeight` rather
    /// than left as bare literals on `trackPickerContent`'s `.frame(...)`,
    /// matching every other picker sizing constant here.
    private static let trackPickerIdealWidth: CGFloat = 320
    private static let trackPickerMaxWidth: CGFloat = 360

    /// Shared open/close transition for the track picker panel — one
    /// constant so the open and close feel identical rather than drifting
    /// apart across the several call sites that toggle `isShowingTrackPicker`
    /// (the button, the backdrop tap, each row's selection). Reintroduced
    /// after confirming the panel reliably shows *without* it — see
    /// `trackSelectionButton`'s doc comment on why a `.transition` was the
    /// first thing stripped out while diagnosing that.
    private static let trackPickerAnimation: Animation = .easeOut(duration: 0.18)

    /// Drill-down/back navigation between picker pages, distinct from
    /// `trackPickerAnimation` above — slower and `.easeInOut` rather than
    /// `.easeOut`, matching `UINavigationController`'s own push/pop timing
    /// (~0.3s, symmetric acceleration) rather than the snappier pop-open
    /// feel appropriate for the panel itself appearing/disappearing.
    private static let trackPickerNavigationAnimation: Animation = .easeInOut(duration: 0.3)

    var body: some View {
        ZStack {
            // Purely decorative, drawn *behind* the blank-space tap catcher
            // below — deliberately its own backmost `ZStack` sibling here,
            // not attached to `content` via `.background()` the way it used
            // to be. A `.background()`'s drawn content (this gradient is
            // real pixels, not `Color.clear`) occludes hit-testing for
            // whatever sits behind *it* — so with the gradient attached to
            // `content` (the frontmost sibling), it silently blocked every
            // tap meant for the catcher below across the *entire* overlay,
            // not just where the gradient visually reads as opaque. Pulling
            // it out to be the actual backmost layer removes that occluder
            // entirely: nothing but the catcher and real controls sit in
            // front of the screen from here on.
            backgroundGradient

            // Full-overlay, effectively-invisible blank-space tap
            // catcher — sits between the decorative background above and
            // `content` below, so every real control in `content` (drawn
            // in front of it, next) claims its own tap first via ordinary
            // SwiftUI front-to-back hit-test resolution; this only ever
            // receives a tap that landed on space nothing else wanted.
            // `onDismissControls` hides the controls immediately — see
            // that closure's own doc comment.
            //
            // Replaces an earlier version of this idea that only armed
            // the middle band (the `Spacer()`s around `transportControls`)
            // and deliberately left `topSection`'s and `scrubberBar`'s own
            // blank space uncaught. That left a real gap: a tap on truly
            // blank space *within* those two rows fell straight through
            // this overlay (neither row has its own `.contentShape`, and a
            // plain `VStack` only hit-tests drawn content) to `PlayerView`'s
            // video-surface gesture underneath, which only *toggles*
            // `showControls` — not a reliable hide — and only after the
            // system's double-tap disambiguation window elapses.
            // `topSection`/`scrubberBar` are fixed-height regardless of
            // orientation while the whole overlay is much shorter in
            // landscape, so that fallthrough ate a proportionally much
            // bigger share of the screen there — exactly why "tap blank
            // space to dismiss" read as unreliable especially in
            // landscape. Covering the *entire* overlay here removes that
            // gap without any manual region bookkeeping: "isn't on an
            // interactive element" now falls out for free from z-order
            // plus every real control's own guaranteed ≥44×44pt
            // `.contentShape` (see each button's doc comment) rather than
            // a hand-carved "protected band."
            //
            // Needs its own opaque-enough-to-hit-test fill, not plain
            // `.clear` — same reasoning as the track-picker backdrop below
            // (SwiftUI won't hit-test a fully `.clear` shape).
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Defensive: either picker's own backdrop (below,
                    // added via a later `.overlay` and therefore already
                    // on top) should always claim a tap first while open,
                    // but guard here too rather than rely solely on
                    // z-order.
                    guard !isShowingTrackPicker, !isShowingChapterPicker else { return }
                    onDismissControls()
                }

            content
        }
        // Full-screen, effectively-invisible tap catcher — placed in its own
        // `.overlay` *before* the panel's below, so the panel (added after,
        // and therefore on top) still receives its own taps while any tap
        // elsewhere on screen falls through to this and closes the picker.
        // Needs its own opaque-enough-to-hit-test fill (SwiftUI won't
        // hit-test a fully `.clear` shape) but visually reads as nothing —
        // without it, a tap meant to dismiss the picker would instead reach
        // the blank-space catcher above (or, before this overlay ever
        // mounted, `PlayerView`'s own single-tap gesture on the video
        // surface underneath) and close the whole controls overlay on top
        // of closing the picker.
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
                    // Clearance for the top button row: its own height plus
                    // the 16pt `.padding()` above and below it in
                    // `topSection`. Derived from `topControlSize` rather
                    // than the flat `76` this used to be — that literal was
                    // right only at the default text size, and at AX3XL the
                    // grown button row pushed straight through the panel's
                    // top edge.
                    .padding(.top, topControlSize + 32)
                    .padding(.trailing, 20)
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        // The chapter picker's own tap-catcher/panel pair, mounted after the
        // track picker's so it sits above it in z-order. The two are never
        // open at once in practice (opening either is a tap that would have
        // dismissed the other first), so this ordering is belt-and-braces
        // rather than load-bearing.
        .overlay {
            if isShowingChapterPicker {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(ChapterPickerOverlay.animation) { isShowingChapterPicker = false }
                    }
            }
        }
        // Anchored bottom-leading, under the current-chapter button that
        // opens it (which sits at the leading edge just below the scrubber),
        // rather than top-trailing like the track picker under *its* button.
        // The bottom padding clears the scrubber row and the chapter button
        // itself — an approximate anchor, same as the track picker's own
        // `.padding(.top, 76)`, not a measured one. Smaller in landscape,
        // matching `ChapterPickerOverlay.maxHeight`'s own reduced cap there
        // — see its doc comment for why landscape needs this at all.
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
    }

    /// `topSection`/`transportControls`/`scrubberBar` stacked as before —
    /// pulled out of `body` only so the new blank-space tap catcher there
    /// can sit behind it as a `ZStack` sibling. Deliberately carries no
    /// `.background()` of its own anymore — see `backgroundGradient`'s doc
    /// comment for why that moved out to its own layer — so this is purely
    /// the real, interactive content: wherever it has nothing drawn (the
    /// `Spacer()` gaps), a tap correctly falls straight through to the
    /// catcher behind it, same as it always has for a bare `VStack`.
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

    /// The corner-anchored logo gradient + bottom darkening, previously
    /// attached to `content` via `.background()`. Moved out to be its own
    /// backmost `ZStack` sibling in `body` rather than staying attached
    /// there — see `body`'s own doc comment for why: a `.background()`'s
    /// drawn content (this is real gradient pixels, not `Color.clear`)
    /// occludes hit-testing for whatever's behind *it*, which silently
    /// blocked the blank-space tap catcher across the whole overlay once
    /// that catcher became a `ZStack` sibling rather than something inside
    /// `content` itself. As its own backmost layer here, nothing sits
    /// between the screen and this decoration, so it can no longer occlude
    /// anything.
    private var backgroundGradient: some View {
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
        // Without this, the gradient is sized/positioned to this view's own
        // safe-area-respecting frame, not the true screen bounds — same
        // video-surface treatment `PlayerView` already gives the player's
        // video layer. Left off, the gradient falls short of the physical
        // edges (most visible in landscape, where the safe-area inset is on
        // the corner side this gradient is meant to bleed into). The
        // buttons/logo/scrubber themselves stay out of this — only this
        // decorative layer ignores the safe area, so controls still avoid
        // the sensor housing/home indicator the way they should.
        .ignoresSafeArea()
        // Purely decorative — explicitly not part of hit-testing (belt and
        // braces alongside moving it behind the catcher above; harmless
        // either way since nothing here has a gesture attached).
        .allowsHitTesting(false)
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
                        // `.system(size: topGlyphSize)` rather than
                        // `.title2` — identical at the default text size
                        // (Title 2 *is* 22pt), but clamped at the top of
                        // the Dynamic Type range so this row can't outgrow
                        // its own width. See `topControlSize`.
                        .font(.system(size: topGlyphSize))
                        // Pads the drawn glyph out to HIG's 44×44 minimum
                        // touch target — see `body`'s blank-space tap
                        // catcher doc comment for why every real control
                        // here now needs an explicit, reliable tap target:
                        // once blank space anywhere is tappable-to-dismiss,
                        // a control with a smaller-than-drawn hit area is
                        // easy to narrowly miss and misfire a dismiss
                        // instead. Same pattern `ProfileView.swift`'s
                        // GitHub link uses.
                        .frame(width: topControlSize, height: topControlSize)
                        .contentShape(Rectangle())
                }

                Spacer()

                // Grouped with its own spacing rather than relying on the
                // outer `HStack`'s (there's only ever been one trailing
                // button until now) — matches the touch-target spacing
                // `transportControls` already uses between its three
                // buttons.
                HStack(spacing: 20) {
                    // Omitted where the system won't act on the lock at all
                    // — see `RotationLock.isSupported`, which is `false` on
                    // a multitasking-capable iPad. Omitted rather than shown
                    // disabled, matching the PiP and playback-stats buttons
                    // below: this one used to render, toggle its own icon to
                    // the locked badge, and have no effect whatsoever, which
                    // reads as a broken feature rather than an unavailable
                    // one.
                    if RotationLock.isSupported {
                        Button {
                            onInteract()
                            onToggleRotationLock()
                        } label: {
                            // The open/closed padlock swap alone (no background
                            // change) turned out too subtle to notice at a
                            // glance against a busy, constantly-changing video
                            // frame — confirmed against a real device. Locked
                            // now also gets a solid white "badge" behind it
                            // (glyph flips to black for contrast on top of
                            // that), the same active/on-state affordance a
                            // system control center toggle uses; unlocked stays
                            // a plain icon with no chrome, matching every other
                            // button in this row.
                            Image(systemName: isRotationLocked ? "lock.rotation" : "lock.rotation.open")
                                .font(.system(size: topGlyphSize))
                                .foregroundStyle(isRotationLocked ? .black : .white)
                                .frame(width: topBadgeSize, height: topBadgeSize)
                                .background {
                                    if isRotationLocked {
                                        Circle().fill(Color.white)
                                    }
                                }
                                // The visible badge stays smaller than the tap
                                // target — an outer frame the badge is centered
                                // in carries the ≥44pt target. See the close
                                // button above for why that matters now, and
                                // `topControlSize` for why all three sizes are
                                // scaled together rather than pinned.
                                .frame(width: topControlSize, height: topControlSize)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(isRotationLocked ? Text("Unlock rotation") : Text("Lock rotation"))
                        .animation(.easeInOut(duration: 0.15), value: isRotationLocked)
                    }

                    trackSelectionButton

                    // Omitted entirely rather than shown disabled — PiP is
                    // only ever unavailable because the active session is on
                    // AetherEngine's software route (see `PlaybackEngine
                    // .onPictureInPicturePossibleChange`'s doc comment) or
                    // because AVKit hasn't yet reported the layer ready, and
                    // neither is a state worth surfacing an inert button for.
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
                        .animation(.easeInOut(duration: 0.15), value: isPlaybackStatsVisible)
                    }

                    // Landscape-only — but keyed off `isLandscapeWindow`
                    // (the window's own shape, measured by `PlayerView`)
                    // rather than the `isLandscape` size-class check the
                    // rest of this file uses. `verticalSizeClass ==
                    // .compact` is iPhone's landscape signal and stays
                    // `.regular` on iPad in *both* orientations, so gating
                    // this on it meant iPad never got a zoom affordance at
                    // all — not this button, and not the double-tap or
                    // pinch in `PlayerView` that share the gate. That left
                    // 2.40:1 content in iPad portrait rendering 349pt tall
                    // inside an 1180pt screen with no way to fill it.
                    //
                    // Window shape rather than `interfaceOrientation`
                    // deliberately: it's the app's established pattern
                    // (`HomeView`, `SeasonEpisodeList`, `CollectionItemList`
                    // all prefer `.onGeometryChange` over a `UIScreen`/
                    // key-window read), it re-evaluates on its own, it can't
                    // be fooled by this screen's own rotation lock, and in
                    // Split View it describes the window the video is
                    // actually in rather than the device around it.
                    //
                    // No on-state badge the way rotation-lock/stats above
                    // get one — unlike "locked"/"visible", the glyph itself
                    // already swaps direction to show which state a tap
                    // leads to, so a second, redundant indicator (per direct
                    // feedback) wasn't needed here.
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
            // These buttons sit outside `backgroundGradient`'s corner
            // ellipse (measured: it's down to ~9% opacity by the time it
            // reaches the trailing edge), so in landscape — where the video
            // reaches the top of the screen — they're white on unmodified
            // video. See `controlScrim`.
            .modifier(controlScrim)
            .padding()

            titleRow
        }
    }

    /// Which page of the track picker is showing — `.root` (the
    /// "Audio"/"Subtitles" entry rows) when both categories have a choice to
    /// make, one of the leaf pages otherwise (see `trackSelectionButton`,
    /// which skips straight to the one applicable leaf rather than showing a
    /// `.root` page with a single row on it). Reset by
    /// `trackSelectionButton`'s tap handler every time the picker opens, so
    /// it never reopens mid-drill-down from wherever it was left last time.
    private enum TrackPickerPage: Equatable {
        case root
        case audio
        case subtitle
    }

    @State private var trackPickerPage: TrackPickerPage = .root

    /// A leaf page's identity — narrower than `TrackPickerPage`, which also
    /// has a `.root` case with no equivalent here. `displayedLeafPage` below
    /// is never root (see its own doc comment), so this type makes that
    /// invariant structural rather than relying on an "unreachable" `switch`
    /// case that has to be trusted by inspection.
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

    /// Which leaf page's *content* is currently built, independent of
    /// `trackPickerPage` — see `leafPage`'s doc comment for why this needs
    /// to be tracked separately rather than just switching on
    /// `trackPickerPage` directly.
    @State private var displayedLeafPage: TrackPickerLeaf = .audio

    /// The picker panel's current height, driving `trackPickerContent`'s
    /// outer `.frame(height:)` directly — a plain `@State` rather than a
    /// value computed reactively from `trackPickerPage` inside the view
    /// body, so it's a genuinely independent, ordinary animatable property
    /// with no `.transition`/`.animation(_:value:)` modifier anywhere near
    /// it to interact badly with (see `navigateToTrackPickerPage`'s doc
    /// comment for why that mattered enough to structure it this way).
    @State private var trackPickerHeight: CGFloat = 0

    /// The one place that changes `trackPickerPage` after the picker's
    /// initial open (`trackSelectionButton` sets the *first* page directly,
    /// before anything is on screen to animate). `displayedLeafPage` updates
    /// first, outside the animated block, and only for a real leaf — going
    /// back to `.root` leaves whatever leaf was last shown in place, so it
    /// still has real content to slide away with instead of going blank
    /// mid-exit. `trackPickerHeight` and `trackPickerPage` then change
    /// together inside the *same* `withAnimation`, so the panel's resize and
    /// `leafPage`'s slide (driven by `trackPickerPage`, via its `.offset` in
    /// `trackPickerContent`) play in sync as one motion, the same way a
    /// native `UINavigationController` push both slides the new page in and
    /// resizes its own nav bar together rather than as two separately-timed
    /// steps. Both are plain `@State` writes with nothing else watching
    /// them, unlike the `.transition`-based approaches tried before this —
    /// see `trackPickerContent`'s doc comment — so there's no ambient
    /// animation-cascading risk in combining them here.
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

    /// Audio/subtitle track picker. A compact panel — not the full sheet
    /// (`TrackSelectionSheet`) this used to present, for what's really just
    /// a small in-place choice, not a task that ever warranted a dedicated
    /// screen. The root page's "Audio"/"Subtitles" rows only appear when
    /// there's an actual choice to make there: `hasAudioChoice` requires
    /// more than one audio track (a single-track asset has nothing to pick
    /// between), and `hasSubtitleChoice` requires at least one subtitle
    /// track at all. When only one of the two applies, the tap handler below
    /// skips the root page and opens straight into that one leaf — no point
    /// showing a picker whose only choice is which single row to tap. When
    /// *neither* applies — e.g. a single-audio-track asset with no
    /// subtitles — the button disables itself and dims rather than opening
    /// an empty picker.
    ///
    /// Hand-rolled overlay content (see `body`'s two `.overlay`s), not a
    /// plain `Menu`, `List`-in-`.popover`, or even a bare `.popover` (all
    /// tried first): a native `Menu`'s width/font are entirely
    /// system-controlled, which left long commentary-track titles wrapping
    /// across 3+ cramped lines with no way to widen the popup or shrink the
    /// text to compensate. Swapping that for a `List` fixed the sizing but
    /// not the legibility — `List` brings its own translucent system
    /// background that read poorly here. Moving that same content into a
    /// plain `.popover` (an explicit `.presentationBackground` in place of
    /// `List`'s) fixed *that*, but introduced a new problem: the system's
    /// own popover chrome — the arrow/rounded-rect border `UIPopoverBackgroundView`
    /// draws, independent of `.presentationBackground` — kept its own
    /// default light fill, so during the open/close transition that light
    /// chrome and this view's dark content visibly animated as two
    /// separate layers moving slightly out of step. A plain view positioned
    /// with `.overlay(alignment:)` is one single layer with one transition,
    /// so there's nothing left for it to visibly desync against.
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
            // Set directly (not via `navigateToTrackPickerPage`) — this is
            // the picker's very first page, appearing together with the
            // whole panel via its own open/close transition below, not a
            // drill-down with anything to slide.
            trackPickerHeight = min(estimatedHeight(for: trackPickerPage), Self.trackPickerMaxHeight)
            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = true }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: topGlyphSize))
                // The dimmed unavailable state is exempt from the contrast
                // floor, but Increase Contrast is still the setting of
                // someone who needs the difference between "dim" and
                // "gone" to be readable — so lift it rather than leave it.
                .opacity(hasAnyChoice ? 1 : (isIncreasedContrast ? 0.6 : 0.4))
                .frame(width: topControlSize, height: topControlSize)
                .contentShape(Rectangle())
        }
        .disabled(!hasAnyChoice)
    }

    /// A deterministic, synchronous *estimate* of a page's content height —
    /// not a real measurement. Two real `GeometryReader`+`PreferenceKey`
    /// measurement approaches were tried first (measuring the visible
    /// `ScrollView`'s own content in place, then a decoupled hidden
    /// `.fixedSize` copy of it) and *both* ended up with the panel rendering
    /// at zero size — some combination of SwiftUI's layout engine and this
    /// view's own conditionally-mounted, animated-transition, nested-in-an-
    /// `.overlay` context meant the height either never resolved away from
    /// its initial 0 or resolved to 0 outright, and nothing short of trial
    /// and error on a real device (unavailable here) was pinning down which.
    /// Row counts, by contrast, are already known synchronously
    /// (`viewModel.audioTracks.count` etc.) — computing an approximate
    /// height from those needs no measurement pass, no preference-key round
    /// trip, and so has no equivalent "stuck at zero" failure mode at all.
    /// The trade-off is precision: a title long enough to wrap onto 2 lines
    /// makes that one row taller than estimated, so the `ScrollView` below
    /// can end up very slightly short for it — but "slightly short inside a
    /// `ScrollView`" just means an extra half-line of scroll headroom, not a
    /// broken or invisible panel.
    private func estimatedHeight(for page: TrackPickerPage) -> CGFloat {
        // Root's two rows are taller than a leaf row — each carries a title
        // *and* a current-selection subtitle line (see `navigationRow`)
        // where a leaf row is normally one line (see `selectionRow`). A
        // leaf's own height also has to add its header (`leafHeaderHeight`)
        // now that header and rows move together as a single sliding unit
        // (see `leafPage`'s doc comment) rather than living outside the
        // animated area the way `.root` never needed one to.
        switch page {
        case .root:
            return navigationRowHeight * 2 + Self.dividerHeight
        case .audio:
            let count = viewModel.audioTracks.count
            let rows = selectionRowHeight * CGFloat(count) + Self.dividerHeight * CGFloat(max(0, count - 1))
            return leafHeaderHeight + Self.dividerHeight + rows
        case .subtitle:
            // +1 for the "Off" row, which isn't in `subtitleTracks`.
            let count = viewModel.subtitleTracks.count + 1
            let rows = selectionRowHeight * CGFloat(count) + Self.dividerHeight * CGFloat(max(0, count - 1))
            return leafHeaderHeight + Self.dividerHeight + rows
        }
    }

    /// `navigationRow`'s two-line (title + current-selection subtitle) rows
    /// — `.padding(.vertical, 10)` (×2) plus roughly a `.subheadline` and a
    /// `.footnote` line stacked with 2pt spacing.
    ///
    /// `@ScaledMetric`, not a plain constant — and the same goes for the two
    /// below. `estimatedHeight(for:)` is what sizes the whole panel, and the
    /// rows it estimates are real text that grows with Dynamic Type, so a
    /// fixed point value drifts further from the truth the larger the text
    /// gets. Measured on an iPad at AX3XL before this changed: a root row
    /// renders 133.5pt against this 56, so `min(estimatedHeight, ...)` sized
    /// the panel at 113pt, `trackPickerContent`'s `.clipped()` cut the first
    /// row off mid-word, and the "Subtitles" row fell outside the panel
    /// entirely — reachable only by scrolling a panel that gives no visible
    /// sign it scrolls.
    ///
    /// Scaling the estimate keeps the arithmetic shape intact (a real
    /// measurement here is a documented dead end — see
    /// `estimatedHeight(for:)`) while tracking what the rows actually do.
    /// `relativeTo: .subheadline` because that's the title line each row's
    /// height is driven by.
    @ScaledMetric(relativeTo: .subheadline) private var navigationRowHeight: CGFloat = 56
    /// `selectionRow`'s rows — `.padding(.vertical, 10)` (×2) plus a
    /// `.subheadline` title and, for most tracks, a `.footnote` metadata
    /// line underneath (see `PlaybackTrack.metadata`). Sized for that
    /// two-line case since it's the common one; a track with no flags at
    /// all renders one line shorter than estimated, same acceptable-gap
    /// trade-off as a title long enough to wrap (see `estimatedHeight(for:)`
    /// 's doc comment).
    @ScaledMetric(relativeTo: .subheadline) private var selectionRowHeight: CGFloat = 56
    /// `backRow`/`leafTitleRow`'s own height — `.padding(.vertical, 12)`
    /// (×2) plus roughly one `.subheadline` line.
    @ScaledMetric(relativeTo: .subheadline) private var leafHeaderHeight: CGFloat = 44
    /// Stays fixed, unlike the three above — it's a hairline rule, not text.
    private static let dividerHeight: CGFloat = 1

    /// The root page — "Audio"/"Subtitles" navigation rows. Always mounted,
    /// at its own fixed height, regardless of `trackPickerPage` — see
    /// `trackPickerContent`'s doc comment for why this is structured as an
    /// always-present base layer rather than one case of a `switch` that
    /// swaps in and out.
    private var rootPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                navigationRow(
                    systemImage: "waveform", title: String(localized: "Audio"), value: currentAudioTrackTitle
                ) { navigateToTrackPickerPage(.audio) }
                divider
                navigationRow(
                    systemImage: "captions.bubble", title: String(localized: "Subtitles"), value: currentSubtitleTrackTitle
                ) { navigateToTrackPickerPage(.subtitle) }
            }
        }
        .frame(height: estimatedHeight(for: .root))
    }

    /// Slides `leafPage` fully clear of the panel's own bounds when parked
    /// off-screen — bigger than `trackPickerMaxWidth` on purpose, so it's
    /// unambiguously outside the panel regardless of which width between
    /// `trackPickerIdealWidth` and `trackPickerMaxWidth` actually gets used.
    private static let trackPickerSlideOffset: CGFloat = 400

    /// A leaf page (`.audio`/`.subtitle`) for whichever page
    /// `displayedLeafPage` currently names — *not* `trackPickerPage`
    /// directly, and always mounted (not conditionally, the way an earlier
    /// version of this did with `if trackPickerPage != .root`) — see
    /// `trackPickerContent`'s doc comment for why. Its own back/title header
    /// (`backRow`/`leafTitleRow`) is stacked *inside* this same view,
    /// directly above its track list, so both move together as one unit
    /// when the whole thing slides — a separate, independently cross-fading
    /// header was part of what made an earlier version of this read as "a
    /// strong fade" rather than a clean slide.
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
                        trackRows(viewModel.audioTracks) { track in
                            onInteract()
                            viewModel.selectAudioTrack(id: track.id)
                            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                        }

                    case .subtitle:
                        selectionRow(
                            title: String(localized: "Off"),
                            metadata: nil,
                            isSelected: !viewModel.subtitleTracks.contains { $0.isSelected }
                        ) {
                            onInteract()
                            viewModel.selectSubtitleTrack(id: nil)
                            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                        }
                        if !viewModel.subtitleTracks.isEmpty { divider }
                        trackRows(viewModel.subtitleTracks) { track in
                            onInteract()
                            viewModel.selectSubtitleTrack(id: track.id)
                            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                        }
                    }
                }
            }
        }
        .frame(height: min(estimatedHeight(for: displayedLeafPage.page), Self.trackPickerMaxHeight))
        // Opaque, matching the panel's own fill — without this, both this
        // leaf and `rootPage` underneath are transparent apart from their
        // own text/icons, so root's rows would show through wherever this
        // leaf's rows don't happen to cover the exact same pixels mid-slide.
        .background(Color(white: 0.1))
    }

    /// The picker's actual content: `rootPage` as a permanent base layer,
    /// with `leafPage` layered on top, always mounted but pushed off to
    /// `trackPickerSlideOffset` (invisible, clipped by the panel's own
    /// bounds) while `trackPickerPage == .root`, animated back to `0` (
    /// covering root) otherwise. Two things were tried and abandoned before
    /// landing on plain `.offset` + `withAnimation`:
    ///
    /// 1. A single view whose *content* swapped via `.id()` + `.transition`.
    ///    The outgoing and incoming view necessarily animate together as a
    ///    matched pair with no independent "this one stays still" option,
    ///    which read as a cross-dissolve rather than a page landing on top
    ///    of a stationary one (reported as "a strong fade").
    /// 2. Two independent views (`rootPage` + a conditionally-mounted
    ///    `leafPage`) with the leaf's *insertion/removal* carrying a
    ///    `.transition(.move(edge:))`. Correct in principle, but disabling
    ///    the *container's* height animation via `.animation(nil, value:)`
    ///    turned out to cascade down as the ambient transaction for
    ///    everything inside it too, silently killing the leaf's own
    ///    `.transition` right along with it (reported as no animation at
    ///    all, just an instant swap) — and an explicit override
    ///    (`.animation(_:value:)` back on the leaf) didn't reliably survive
    ///    contact with `.transition`'s own insert/remove machinery either.
    ///
    /// Plain `.offset(x:)` sidesteps both: it's not `.transition` at all, so
    /// there's no insert/remove pairing and no ambient-animation cascading
    /// to fight. `trackPickerHeight` below is an ordinary `@State` `CGFloat`
    /// with nothing else watching it, changed in the same `withAnimation` as
    /// `trackPickerPage` (see `navigateToTrackPickerPage`) — so the resize
    /// and the slide play as one synchronized motion rather than the panel
    /// growing/shrinking independently of the page moving across it.
    @ViewBuilder
    private var trackPickerContent: some View {
        ZStack(alignment: .topLeading) {
            rootPage

            leafPage
                .offset(x: trackPickerPage == .root ? Self.trackPickerSlideOffset : 0)
                // Belt-and-suspenders alongside the panel's own `.clipped()`
                // below — without this, the leaf parked off-screen could
                // still intercept taps meant for `rootPage` underneath it.
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
        // `.ignore`, not `.combine` — the leading chevron is purely
        // decorative wayfinding, not information VoiceOver should read on
        // its own; the plain "Back" label already conveys what this button
        // does regardless of which leaf it's read from.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Back"))
    }

    private func leafTitleRow(for page: TrackPickerLeaf) -> some View {
        Text(page == .audio ? String(localized: "Audio") : String(localized: "Subtitles"))
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    /// A root-page row that drills into a leaf page rather than selecting
    /// anything itself — its trailing chevron (vs. a leaf row's checkmark)
    /// is what signals that, and `value` previews the leaf's current
    /// selection so it's visible without the extra tap. `systemImage`
    /// (`"waveform"` for Audio, `"captions.bubble"` for Subtitles — the
    /// latter shared with `trackSelectionButton`'s own icon deliberately,
    /// since it's Apple's canonical captions/subtitles glyph) gives the two
    /// rows the same "leading icon, title, chevron" shape as a native
    /// Settings row.
    private func navigationRow(
        systemImage: String, title: String, value: String, action: @escaping () -> Void
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
        // `.ignore` — the leading icon and trailing chevron are decorative;
        // `value` (the current selection, e.g. "Default"/"Off") is folded
        // into the label since there's no separate `.accessibilityValue`
        // reader for a row that navigates rather than adjusts in place.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(title), \(value)"))
    }

    /// A leaf-page row's list of tracks, dividers interleaved between
    /// entries (not after the last) — the same separator `List` would draw
    /// for free, hand-rolled here since this view doesn't use `List` (see
    /// `trackSelectionButton`'s doc comment for why).
    @ViewBuilder
    private func trackRows(_ tracks: [PlaybackTrack], onSelect: @escaping (PlaybackTrack) -> Void) -> some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            if index > 0 { divider }
            selectionRow(title: track.title, metadata: track.metadata, isSelected: track.isSelected) {
                onSelect(track)
            }
        }
    }

    /// `metadata` (Default/Forced/Hearing Impaired/Commentary/External, see
    /// `AetherPlaybackEngine.metadataLabel(for:)`) renders as a second,
    /// `.footnote`-styled line under `title` when present — same "title +
    /// secondary line" shape as `navigationRow` above, just with a
    /// selection checkmark leading instead of a chevron trailing. `nil`
    /// collapses back to a single line rather than leaving an empty gap.
    private func selectionRow(title: String, metadata: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                // Reserves the checkmark's width whether selected or not
                // (`.opacity` rather than an `if`) so the title doesn't
                // shift left/right as selection changes between rows.
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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let logoURL = viewModel.offlineLogoURL ?? item.logoImageURL {
                        if logoURL.isFileURL {
                            LocalFileImage(url: logoURL, contentMode: .fit)
                                .frame(maxWidth: 240, maxHeight: 60, alignment: .leading)
                        } else {
                            LogoImageView(url: logoURL, fallback: titleText(item.railTitle))
                                .frame(maxWidth: 240, maxHeight: 60, alignment: .leading)
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
                    // touch target. It measured 51×14.5pt before — under
                    // even the 28pt floor — despite being a real control,
                    // as its own `.accessibilityHint` below says outright.
                    // Has to go on the *label*, not outside the `Button`: a
                    // button hit-tests where its label paints, so a frame
                    // applied outside grows the layout (and the
                    // accessibility frame that gets measured) while leaving
                    // the real target the size of the text. Same fix, same
                    // reason, as the close button in `topSection`.
                    //
                    // Layout-neutral at every text size: `scrubberTrack`
                    // already makes this row at least 44pt tall, so the
                    // timestamp just centers in height the row had anyway.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(endTimeAccessibilityLabel)
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
