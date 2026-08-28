import SwiftUI
import os

/// Full-screen playback presented over whatever screen initiated it.
/// Renders AetherEngine's video surface with a custom transport-controls
/// overlay.
struct PlayerView: View {
    private static let logger = Logger(subsystem: "com.dionysus.player", category: "PlayerView")

    let itemID: String
    var startFromBeginning: Bool = false
    var mediaSourceID: String? = nil
    /// Fired from `close()` with this session's final position — see
    /// `PlaybackSessionOutcome`'s own doc comment for why. `nil` (the
    /// default) for any presentation that doesn't need it.
    var onPlaybackEnded: ((PlaybackSessionOutcome) -> Void)? = nil
    /// Fired when the "Up Next" prompt (`NextUpOverlay`) advances to the
    /// next episode — via its own Play Now button, or automatically once
    /// its countdown reaches zero — with that episode's id, right before
    /// this `PlayerView` dismisses itself. `nil` (the default) for
    /// `MovieDetailView`/`CollectionDetailView`, whose items are never
    /// `.episode`, so `PlayerViewModel.nextEpisode` never resolves to
    /// anything there and this never fires.
    ///
    /// `ShowDetailView` implements it by *stashing* the id (a local
    /// `@State`), not by re-pointing `playbackRequest` at it directly —
    /// see `advanceToNextEpisode()`'s doc comment for why setting an
    /// already-presented `.fullScreenCover(item:)`'s bound value straight
    /// to a new id, while still presented, doesn't reliably re-present:
    /// confirmed live (2026-08-17), it doesn't just fail to animate a
    /// clean transition, the actual episode that ends up on screen after
    /// is wrong and unplayable. `playbackRequest` only ever gets set from
    /// `onDismiss`, once the cover has genuinely gone through `nil` first —
    /// the same nil-then-non-nil path every ordinary Play/Resume tap
    /// already takes.
    var onRequestNextItem: ((String) -> Void)? = nil
    /// Non-nil plays this local downloaded copy instead of fetching
    /// `itemID` over the network — see `PlayerViewModel.downloadedItem`'s
    /// doc comment and the offline-downloads plan's "Offline playback
    /// wiring" section. `itemID` above should still be
    /// `downloadedItem.itemID` in that case.
    var downloadedItem: DownloadedItem? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    /// Gates `scheduleAutoHide()` below — confirmed live (VoiceOver on,
    /// real device) that the 3-second auto-hide is actively hostile to
    /// VoiceOver use: it doesn't give enough time to swipe to a control and
    /// double-tap it before the whole row fades and goes
    /// `.accessibilityHidden`. Controls simply never auto-hide while
    /// VoiceOver is running — still dismissible via the existing explicit
    /// blank-space-tap gesture (`dismissControls()`), just not on a timer
    /// that can't outrun VoiceOver's own navigation speed.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var viewModel: PlayerViewModel?
    /// Set when `setUpIfNeeded()`'s `AetherPlaybackEngine()` construction
    /// throws — previously swallowed with `try?`, which left this view
    /// stuck on `LoadingView()` forever with no `viewModel` to ever hold an
    /// `errorMessage`, and no indication anything had gone wrong at all.
    @State private var setupError: String?
    @State private var showControls = true
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    /// Whether `PlayerControlsOverlay`'s audio/subtitle track picker is
    /// showing — see `scheduleAutoHide()`'s guard, the reason this needs to
    /// live here rather than as that overlay's own local `@State`: without
    /// it, the auto-hide timer had no way to know the picker was open and
    /// would fade the whole controls row (picker included) out from under
    /// the user reading it.
    @State private var isShowingTrackPicker = false
    /// Mirrors `RotationLock`'s app-wide state for the button's own icon —
    /// see `toggleRotationLock()`/`close()` for why this view is what keeps
    /// the two in sync rather than `PlayerControlsOverlay` reading
    /// `RotationLock` directly.
    @State private var isRotationLocked = false
    /// Mirrors the engine's own zoom mode for the same reason
    /// `isRotationLocked` mirrors `RotationLock` — see that property's doc
    /// comment. Driven by `handleDoubleTap()`/`pinchZoomGesture` below, and
    /// force-reset to `.fit` on leaving landscape (see `isLandscape`'s doc
    /// comment).
    @State private var zoomMode: VideoZoomMode = .fit
    /// Whether `PlaybackStatsOverlay` (the "stats for nerds" panel) is
    /// showing. Unlike `showControls`, this has no auto-hide/fade — it's a
    /// plain on/off toggle that only the info button in
    /// `PlayerControlsOverlay` flips, per that overlay's own doc comment on
    /// why it's driven separately from the rest of the controls.
    @State private var showPlaybackStats = false
    /// Guards `advanceToNextEpisode()` against firing a second time while
    /// its own `await viewModel.stop()` is still in flight — the
    /// `.onChange(of: nextUpSecondsRemaining)` trigger below could
    /// otherwise re-fire on some intermediate re-render before
    /// `onRequestNextItem` has actually swapped this screen out from under
    /// itself.
    @State private var isAdvancingToNextEpisode = false
    /// Pending "fade the controls out" work item — armed by `scheduleAutoHide()`
    /// whenever playback is actually running, cancelled the moment it isn't.
    @State private var autoHideTask: Task<Void, Never>?
    /// True from the moment `SkipSegmentOverlay`'s button is tapped until
    /// playback resumes — suppresses the `viewModel?.state`
    /// `.onChange` below from doing its normal "anything other than
    /// `.playing` forces the main transport chrome back on screen" thing,
    /// which a segment skip's own `.seeking`/`.buffering` spell would
    /// otherwise trigger same as any other pause/stall. `SkipSegmentOverlay`
    /// shows its own small spinner in the skipped button's place instead —
    /// see `isSkipBuffering`.
    @State private var isSkippingSegment = false
    /// Invalidates a stale `isSkippingSegment` reset — see the safety-net
    /// `Task` in `SkipSegmentOverlay`'s `onSkip` closure below for why one
    /// exists at all (a very small skip might never visibly enter
    /// `.seeking` before landing, the same gap `PlayerControlsOverlay`'s
    /// scrubber documents) and why it needs a generation token: without
    /// one, an in-flight timeout from an *earlier* skip could clear
    /// suppression for a *later* one still in progress if the user tapped
    /// Skip again within that window.
    @State private var skipSegmentGeneration = 0

    /// `.compact` is iPhone's landscape signal (see `HeroRailView.isLandscape`
    /// for the same check/caveat: this stays `.regular` in both orientations
    /// on iPad, so the zoom gestures below are effectively iPhone-only —
    /// acceptable here since an iPad's video area rarely fills the whole
    /// screen either way, unlike an iPhone in landscape).
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Drives `SkipSegmentOverlay`'s spinner — `isSkippingSegment` alone
    /// stays true for the whole suppression window (including once
    /// playback has already resumed but the reset hasn't landed yet on some
    /// intermediate render), so this also requires the engine to actually
    /// be in a buffering-like state right now, matching
    /// `PlayerControlsOverlay.isBuffering`'s own state list. Keeps the
    /// spinner honest about "if necessary" — a skip that lands
    /// near-instantly shouldn't flash one at all.
    private var isSkipBuffering: Bool {
        guard isSkippingSegment else { return false }
        switch viewModel?.state {
        case .loading, .seeking, .buffering, .reconnecting: return true
        default: return false
        }
    }

    /// How long the controls sit idle before fading, once armed. Only
    /// applies while playback is running — see `scheduleAutoHide()`.
    private static let autoHideDelay: Duration = .seconds(3)
    /// Deliberately asymmetric: fading out is a passive, ambient thing that
    /// happens after idle time, so it can afford to be leisurely; revealing
    /// is a direct response to a tap/interaction and needs to feel
    /// immediate, so it's much quicker. See `body`'s doc comment on the
    /// overlay for why `.easeInOut`'s own default duration wasn't actually
    /// the problem an earlier pass here fixed.
    private static let fadeOutAnimation: Animation = .easeInOut(duration: 0.5)
    private static let fadeInAnimation: Animation = .easeInOut(duration: 0.1)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let viewModel {
                viewModel.engine.makeSurface()
                    .ignoresSafeArea()
                    // Double tap takes priority — `exclusively(before:)`
                    // holds the single tap back until a double tap's own
                    // window has passed without a second tap landing, the
                    // same disambiguation a bare `UITapGestureRecognizer`
                    // pair would need `require(toFail:)` for. Without this,
                    // both taps of a double tap register as sequential
                    // single taps, showing then immediately re-hiding
                    // controls instead of toggling zoom.
                    .gesture(
                        TapGesture(count: 2)
                            .onEnded { handleDoubleTap() }
                            .exclusively(before: TapGesture(count: 1).onEnded { handleSingleTap() })
                    )
                    // Simultaneous, not exclusive, with the tap gesture
                    // above — a pinch is a distinct two-finger interaction
                    // that can't be confused with either kind of tap, so
                    // there's no disambiguation needed between them.
                    .simultaneousGesture(pinchZoomGesture)

                // Above the video surface but below the transport chrome —
                // visible independent of `showControls` (subtitles aren't
                // "controls", they shouldn't fade with them), with its own
                // bottom clearance animating in step with the controls fade
                // instead. See `SubtitleOverlayView.controlsVisible`'s doc
                // comment.
                SubtitleOverlayView(viewModel: viewModel, zoomMode: zoomMode, controlsVisible: showControls)
                    .ignoresSafeArea()

                // Between the video surface and `PlayerControlsOverlay`,
                // per that overlay's own doc comment — the "closest
                // possible layer to the video" placement the feature was
                // specified with. Always mounted, like `PlayerControlsOverlay`
                // below, with `showPlaybackStats` driving its own internal
                // `isVisible`/opacity rather than this conditionally
                // inserting/removing it — see `PlaybackStatsOverlay`'s doc
                // comment for why a mount/unmount toggle here visibly
                // shifted the rest of the player UI.
                PlaybackStatsOverlay(viewModel: viewModel, zoomMode: zoomMode, isVisible: showPlaybackStats)

                // Always mounted — animating `.opacity` directly on a
                // permanent view, rather than conditionally including it
                // with `.transition(.opacity)`, is deliberate. The overlay
                // reads `viewModel.currentTime`, which ticks ~10 times a
                // second during playback (AetherEngine's clock publisher);
                // every one of those ticks forces a fresh, *un*-animated
                // render pass through the same view tree. Against a mount/
                // unmount transition, each of those passes competed with
                // the in-flight removal animation and won, since they carry
                // no transaction of their own — the fade visibly never got
                // more than a frame or two in before the next tick snapped
                // it back to fully rendered, right up until the view
                // actually unmounted, which read as an instant cut rather
                // than the ~0.5s fade this is supposed to be. A plain
                // `.opacity` value doesn't have that problem: it's a normal
                // stored property SwiftUI interpolates across whatever
                // transaction was active when it last changed, and an
                // unrelated non-animated re-render elsewhere just re-reads
                // the same interpolated value mid-flight instead of
                // resetting it.
                PlayerControlsOverlay(
                    viewModel: viewModel,
                    isScrubbing: $isScrubbing,
                    scrubTime: $scrubTime,
                    isShowingTrackPicker: $isShowingTrackPicker,
                    onClose: { Task { await close() } },
                    isRotationLocked: isRotationLocked,
                    onToggleRotationLock: toggleRotationLock,
                    isPlaybackStatsVisible: showPlaybackStats,
                    onTogglePlaybackStats: { showPlaybackStats.toggle() },
                    zoomMode: zoomMode,
                    onToggleZoomMode: { setZoomMode(zoomMode.toggled) },
                    onEnterPictureInPicture: { viewModel.startPictureInPicture() },
                    onInteract: scheduleAutoHide,
                    onDismissControls: dismissControls
                )
                .opacity(showControls ? 1 : 0)
                // Disabled the instant `showControls` flips, not once the
                // fade animation finishes — otherwise the still-fading (but
                // already logically "hidden") overlay would keep
                // intercepting taps meant to reveal it again, since its own
                // background gradient is filled content that hit-tests just
                // like its buttons do.
                .allowsHitTesting(showControls)
                // Keeps VoiceOver from landing on buttons that are present
                // but invisible while faded out.
                .accessibilityHidden(!showControls)

                // Above `PlayerControlsOverlay` (added after it in this
                // ZStack), and — unlike it — not gated on `showControls` at
                // all: see `NextUpOverlay`'s own doc comment for why it's
                // meant to be complementary to the transport chrome rather
                // than part of it, staying shown/interactive whether the
                // controls are faded in or out.
                NextUpOverlay(
                    nextEpisode: viewModel.nextEpisode,
                    secondsRemaining: viewModel.nextUpSecondsRemaining,
                    totalSeconds: viewModel.nextUpTotalCountdownSeconds,
                    onPlayNow: { Task { await advanceToNextEpisode() } },
                    onCancel: { viewModel.dismissNextUp() }
                )

                // Same bottom-trailing slot as `NextUpOverlay`, same "always
                // mounted" treatment — see `SkipSegmentOverlay`'s own doc
                // comment for why the two never actually compete for it.
                SkipSegmentOverlay(
                    segment: viewModel.currentSkipSegment,
                    isBuffering: isSkipBuffering,
                    onSkip: { segment in
                        isSkippingSegment = true
                        skipSegmentGeneration += 1
                        let generation = skipSegmentGeneration
                        viewModel.skipSegment(segment)
                        // Safety net: see `skipSegmentGeneration`'s doc
                        // comment for why this is generation-guarded rather
                        // than an unconditional reset.
                        Task {
                            try? await Task.sleep(for: .seconds(5))
                            guard generation == skipSegmentGeneration else { return }
                            isSkippingSegment = false
                        }
                    },
                    // No `isSkippingSegment`/buffering dance here, unlike
                    // `onSkip` above — dismissing never seeks (see
                    // `PlayerViewModel.dismissSkipSegment(_:)`'s doc
                    // comment), so there's nothing for the engine to
                    // buffer through.
                    onDismiss: { segment in
                        viewModel.dismissSkipSegment(segment)
                    }
                )

                // Above the transport chrome (added after it in this ZStack)
                // — while a PiP window has this session's picture, nothing
                // underneath, controls included, is visible or meant to be
                // interactive. See `PictureInPictureOverlay`'s own doc
                // comment for why it (and the video surface above) stay
                // mounted rather than being swapped in/out.
                PictureInPictureOverlay(isVisible: viewModel.isPictureInPictureActive)

                // VoiceOver-only: an explicit, always-reachable way back to
                // the transport chrome once it's hidden — the video
                // surface's own tap-to-reveal gesture (`handleSingleTap()`
                // above) isn't a reliable path for VoiceOver, which
                // navigates by swiping between focusable elements and
                // double-tapping the focused one, not by exploring free-form
                // screen coordinates; see `voiceOverEnabled`'s own doc
                // comment for the full reasoning. Unmounted entirely (not
                // just `.accessibilityHidden`) when VoiceOver is off — this
                // is purely a VoiceOver affordance, not a general extra
                // button — and, unlike `PlayerControlsOverlay`, never gated
                // on `showControls` itself: that's the whole point, it has
                // to stay reachable exactly when everything else is hidden.
                // Vertically centered on the leading edge — the one spot
                // clear of everything else in this ZStack in *either*
                // `showControls` state: `topSection` occupies the top
                // (close leading, rotation-lock/captions/PiP/stats
                // trailing), `scrubberBar` spans the full width at the
                // bottom (including its own leading timestamp — confirmed
                // live this button's original bottom-leading placement sat
                // directly on top of it once controls were visible), and
                // the transport row sits horizontally centered in between.
                // A left-edge vertical center misses all three, so it stays
                // at a fixed, predictable point in VoiceOver's swipe order
                // regardless of what else is visible.
                if voiceOverEnabled {
                    Button(action: handleSingleTap) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.black.opacity(0.55)))
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(
                        showControls
                            ? String(localized: "Hide Player Controls")
                            : String(localized: "Show Player Controls")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding()
                }

                if let errorMessage = viewModel.errorMessage {
                    // `ErrorStateView`/`OfflineStateView` have no opaque
                    // background of their own — every other screen that uses
                    // them replaces a plain content region with nothing else
                    // behind it, so that's never mattered before. Here,
                    // `PlayerControlsOverlay` (and the rest of the transport
                    // chrome) is still fully mounted right underneath, and
                    // was visibly bleeding through every gap around the
                    // icon/text/buttons — confirmed live, 2026-08-24. A
                    // dimming scrim (also blocks taps reaching whatever's
                    // behind it, since a filled `Color` view hit-tests across
                    // its whole frame) plus a bounded, opaque card gives the
                    // error a real "topmost, obviously modal" presentation
                    // instead — same panel language `PlayerControlsOverlay`'s
                    // own track picker already uses (`trackPickerContent`),
                    // rather than either component's default bare-floating
                    // look. Deliberately a *light* dim (matching a standard
                    // iOS modal scrim, not the near-opaque 0.85 first tried) —
                    // the card's own opaque fill plus border/shadow is what
                    // reads as "on top," not blacking out the always-present
                    // top toolbar/title underneath, which stayed legible
                    // before this whole fix existed and shouldn't get
                    // crushed to near-invisibility now (confirmed live,
                    // 2026-08-24).
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()

                        // A terminal failure that coincides with the app
                        // already being offline (the common case for a LAN
                        // drop — the same outage kills
                        // `reportPlaybackProgress` too, which is what keeps
                        // `ConnectivityMonitor` current) gets the shared
                        // offline screen with a retry that resumes in place.
                        // Otherwise, branch on `failureCategory`: a
                        // `.refused` failure (an access refusal, or content
                        // this build/device can never play) gets Close
                        // only — Retry can't fix it, and leaving only a
                        // dead-end retry loop with no way out was a real
                        // gap. `.rateLimited` and `.transient` keep Retry
                        // (both are worth retrying — a metered origin is
                        // expected to work again later; everything else is
                        // today's existing "just try again" default) but
                        // *also* get Close now — a Retry-only dead end here
                        // was the same gap `.refused` was already fixed
                        // for, just not yet closed for this branch
                        // (confirmed live, 2026-08-28: a transcode-URL
                        // failure landed here with no way out of the
                        // player at all besides a fruitless Retry loop).
                        Group {
                            if ConnectivityMonitor.shared.isOffline {
                                // No `.tint` override here — unlike
                                // `ErrorStateView` below, `OfflineStateView`'s
                                // primary action is `.buttonStyle
                                // (.borderedProminent)`, which uses the tint
                                // as its *fill*, not just its label/border
                                // color. Forcing that to white produced a
                                // white-on-white button with no visible
                                // label (confirmed live, 2026-08-24) — the
                                // app's own default accent already contrasts
                                // fine as a prominent fill against this dark
                                // card (it's the same button this component
                                // already renders correctly everywhere else
                                // in the app), so it needs no override at
                                // all.
                                OfflineStateView(
                                    retry: {
                                        Task { await viewModel.start(resumeSeconds: viewModel.currentTime) }
                                    },
                                    secondaryActionTitle: String(localized: "Close"),
                                    secondaryAction: { Task { await close() } }
                                )
                            } else if viewModel.failureCategory == .refused {
                                ErrorStateView(
                                    message: errorMessage,
                                    retry: nil,
                                    secondaryActionTitle: String(localized: "Close"),
                                    secondaryAction: { Task { await close() } }
                                )
                                // `.bordered`, not `.borderedProminent` —
                                // tint here only colors the label/border, so
                                // forcing it white is exactly the fix this
                                // one needs (see the color-scheme comment
                                // below for the matching icon/message fix).
                                .tint(.white)
                            } else {
                                ErrorStateView(
                                    message: errorMessage,
                                    retry: { Task { await viewModel.start() } },
                                    secondaryActionTitle: String(localized: "Close"),
                                    secondaryAction: { Task { await close() } }
                                )
                                .tint(.white)
                            }
                        }
                        // `ErrorStateView`/`OfflineStateView`'s icon/message
                        // use `.secondary`, which correctly assumes it's
                        // painting onto whatever the *system* light/dark
                        // appearance actually is, since every other screen
                        // that uses them sits on the ordinary system
                        // background. This card's fill is always dark
                        // regardless of the device's actual appearance
                        // setting, so on a device in Light mode `.secondary`
                        // resolved to a mid-gray meant for a *light*
                        // background — nearly invisible here (confirmed
                        // live, 2026-08-24). Forcing this subtree's color
                        // scheme is what actually fixes it — `.secondary`
                        // then resolves to its dark-appearance value
                        // regardless of the system setting, matching what
                        // this card always visually is. (The `.tint(.white)`
                        // buttons need is applied per-branch above instead,
                        // not here — `.borderedProminent`'s tint is its
                        // *fill*, not just its label/border color, so a
                        // blanket override here would white-out
                        // `OfflineStateView`'s primary button the same way
                        // it just did before this was split out; see that
                        // branch's own comment.)
                        .colorScheme(.dark)
                        // Caps growth to a bounded card instead of the
                        // full-screen fill each view's own body requests —
                        // nested `.frame` proposals cap what the infinite
                        // one inside can claim — and `.fixedSize` on the
                        // vertical axis stops it from stretching to fill the
                        // scrim's full height too, so the card hugs its
                        // actual content instead of forming a tall column.
                        .frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Color(white: 0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12))
                        }
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                        .padding(32)
                    }
                }
            } else if let setupError {
                ErrorStateView(message: setupError) {
                    Task {
                        self.setupError = nil
                        await setUpIfNeeded()
                    }
                }
            } else {
                LoadingView()
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await setUpIfNeeded() }
        // The controls only ever fade while `.playing` — every other state
        // (paused, loading, seeking, buffering, reconnecting, ended, failed)
        // both cancels
        // any pending fade and forces them back on screen. That covers not
        // just "don't hide while paused", but also things like a mid-scrub
        // `.seeking`/`.buffering` spell landing right as a stale timer was
        // about to fire, or the controls having been auto-hidden just
        // before the user paused some other way (e.g. a route change).
        //
        // Skipped entirely while PiP is active: a state change reachable
        // from there (e.g. pausing from the system PiP overlay) would
        // otherwise force the transport chrome back on screen over
        // `PictureInPictureOverlay`'s placeholder, with no interaction of
        // the PiP-active `onChange` below to hide it again since that one
        // only fires on a transition of `isPictureInPictureActive` itself.
        //
        // Also skipped while `isSkippingSegment` — a segment skip's own
        // `.seeking`/`.buffering` spell shouldn't reveal the main transport
        // chrome the same way a user-initiated pause/scrub does;
        // `SkipSegmentOverlay` shows its own small spinner instead (see
        // `isSkipBuffering`), and if the chrome happened to already be
        // visible when Skip was tapped, this just leaves it exactly as it
        // was rather than touching it either way.
        .onChange(of: viewModel?.state) { _, newState in
            guard viewModel?.isPictureInPictureActive != true else { return }
            guard newState == .playing else {
                guard !isSkippingSegment else { return }
                autoHideTask?.cancel()
                withAnimation(Self.fadeInAnimation) { showControls = true }
                return
            }
            isSkippingSegment = false
            scheduleAutoHide()
        }
        // Zoom is a landscape-only affordance — leaving landscape with
        // `.fill` still active would otherwise leave a portrait video
        // cropped with no way left to un-zoom it (both gestures below are
        // gated on `isLandscape` too), so force it back to `.fit` the
        // moment the rotation itself takes it out of scope.
        .onChange(of: isLandscape) { _, landscape in
            guard !landscape else { return }
            setZoomMode(.fit)
        }
        // Opening the track picker cancels any pending fade (the guard in
        // `scheduleAutoHide()` blocks a reschedule while it's showing);
        // closing it starts a fresh countdown, the same "you get another
        // full `autoHideDelay` after an interaction" treatment every other
        // tap in this screen already gets via `onInteract`.
        .onChange(of: isShowingTrackPicker) { _, _ in
            scheduleAutoHide()
        }
        // The "automatic" half of the Up Next countdown — reaching 0 with
        // no interaction advances on its own; Play Now/Cancel are the two
        // ways to preempt that. See `NextUpOverlay`'s doc comment for why
        // this is driven by `nextUpSecondsRemaining` reaching 0 rather than
        // a separate timer.
        .onChange(of: viewModel?.nextUpSecondsRemaining) { _, secondsRemaining in
            guard secondsRemaining == 0 else { return }
            Task { await advanceToNextEpisode() }
        }
        // Entering PiP from the in-app button leaves the app foregrounded —
        // unlike every other case `showControls` reacts to, nothing else
        // here (state, orientation, the track picker) changes when that
        // happens, so without this the transport chrome just sat there on
        // screen, on top of `PictureInPictureOverlay`'s placeholder. No
        // `withAnimation` on the way in: PiP itself is instant, so the
        // controls should vanish with it rather than still be mid-fade a
        // moment later. Leaving PiP restores them the same way any other
        // interaction does — a quick fade-in, then a fresh auto-hide
        // countdown if still playing.
        .onChange(of: viewModel?.isPictureInPictureActive) { _, isActive in
            guard let isActive else { return }
            if isActive {
                autoHideTask?.cancel()
                showControls = false
            } else {
                withAnimation(Self.fadeInAnimation) { showControls = true }
                scheduleAutoHide()
            }
        }
    }

    /// The single-tap "show/hide controls" behavior this overlay always
    /// had, now reached only once a double tap has failed to materialize —
    /// see the surface's `.gesture(...)` doc comment. In practice this only
    /// ever *reveals* controls now: `PlayerControlsOverlay`'s own full-bounds
    /// blank-space tap catcher (see its `body`) claims every tap on the
    /// overlay's own bounds while `showControls` is true, so this surface
    /// gesture stops receiving taps at all for as long as controls are
    /// visible — hiding always goes through `dismissControls()` below
    /// instead, not this toggle.
    private func handleSingleTap() {
        let isRevealing = !showControls
        withAnimation(isRevealing ? Self.fadeInAnimation : Self.fadeOutAnimation) {
            showControls.toggle()
        }
        scheduleAutoHide()
    }

    /// Toggles fit/fill, matching the standard streaming-app convention —
    /// but only in landscape (see `isLandscape`'s doc comment) and only
    /// while controls are hidden, so a double tap aimed at dismissing a
    /// button/scrubber doesn't also zoom the video out from under it.
    private func handleDoubleTap() {
        guard isLandscape, !showControls else { return }
        setZoomMode(zoomMode.toggled)
    }

    /// Interchangeable with the double tap above: pinching open (fingers
    /// moving apart, `magnification > 1`) zooms in to `.fill`; pinching
    /// closed zooms back out to `.fit`. Unlike the double tap, this isn't
    /// gated on `showControls` — a two-finger pinch can't be confused with
    /// a tap on a control, so there's no reason to withhold it while the
    /// overlay happens to be showing. A small dead zone around 1.0 avoids
    /// flipping modes on a pinch that barely moved (a light double-tap can
    /// register a tiny incidental magnification).
    private var pinchZoomGesture: some Gesture {
        MagnifyGesture()
            .onEnded { value in
                guard isLandscape, abs(value.magnification - 1) > 0.05 else { return }
                setZoomMode(value.magnification > 1 ? .fill : .fit)
            }
    }

    private func setZoomMode(_ mode: VideoZoomMode) {
        zoomMode = mode
        viewModel?.setZoomMode(mode)
    }

    /// (Re)arms the 3-second auto-hide countdown, replacing any countdown
    /// already pending. A no-op — and clears any pending countdown — unless
    /// controls are actually showing, playback is actually running, and the
    /// track picker isn't up (see `isShowingTrackPicker`'s doc comment —
    /// without that last check, a user who paused to read the picker's
    /// options for a few seconds would have the whole controls row,
    /// including the picker itself, fade out from under them); callers (the
    /// reveal tap, every button/drag in `PlayerControlsOverlay`, and
    /// playback resuming) call this unconditionally on every interaction
    /// rather than checking those themselves, so this is the one place that
    /// decides whether a fade should happen at all.
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard showControls, !isShowingTrackPicker, !voiceOverEnabled, viewModel?.state == .playing else { return }
        autoHideTask = Task {
            try? await Task.sleep(for: Self.autoHideDelay)
            guard !Task.isCancelled else { return }
            withAnimation(Self.fadeOutAnimation) { showControls = false }
        }
    }

    /// A blank-space tap inside `PlayerControlsOverlay` while it's showing —
    /// see `PlayerControlsOverlay.onDismissControls`'s doc comment. Same
    /// fade `scheduleAutoHide()`'s timer branch uses, just triggered
    /// immediately rather than waited out; cancels any pending auto-hide
    /// countdown since there's nothing left for it to do once this has
    /// already hidden the controls.
    private func dismissControls() {
        autoHideTask?.cancel()
        withAnimation(Self.fadeOutAnimation) { showControls = false }
    }

    private func setUpIfNeeded() async {
        guard viewModel == nil, let client = appState.apiClient else { return }
        // Falls back to the stored credentials' userID (not just
        // `currentUser?.id`) so offline playback works from a cold launch
        // that never completed a live sign-in this session — see
        // `RootView`'s `.offline` "View Downloads" escape hatch, which
        // reaches this view with no `currentUser` at all.
        guard let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID else { return }
        let engine: AetherPlaybackEngine
        do {
            engine = try AetherPlaybackEngine()
        } catch {
            Self.logger.error("AetherPlaybackEngine construction failed: \(error.localizedDescription, privacy: .public)")
            setupError = String(localized: "Couldn't start the video player.")
            return
        }
        let newViewModel = PlayerViewModel(
            client: client, userID: userID, itemID: itemID, engine: engine,
            startFromBeginning: startFromBeginning, mediaSourceID: mediaSourceID,
            downloadedItem: downloadedItem, downloadStore: downloadedItem != nil ? appState.downloadManager.store : nil
        )
        viewModel = newViewModel
        await newViewModel.start()
    }

    /// Flips `RotationLock` and this view's own mirror of it together — see
    /// `isRotationLocked`'s doc comment for why `PlayerControlsOverlay`
    /// doesn't just read/write `RotationLock` directly.
    private func toggleRotationLock() {
        isRotationLocked.toggle()
        if isRotationLocked {
            RotationLock.lockToCurrentOrientation()
        } else {
            RotationLock.unlock()
        }
    }

    private func close() async {
        await tearDown()
    }

    /// `NextUpOverlay`'s Play Now button, and the automatic countdown-hits-
    /// zero case (`.onChange(of: nextUpSecondsRemaining)` above). `guard`ed
    /// separately from `tearDown(nextItemID:)` itself (rather than folding
    /// the `nextEpisode` unwrap in there too) since `close()` has no
    /// equivalent id to guard on — it always tears down unconditionally.
    private func advanceToNextEpisode() async {
        guard let viewModel, let nextEpisode = viewModel.nextEpisode, !isAdvancingToNextEpisode else { return }
        isAdvancingToNextEpisode = true
        await tearDown(nextItemID: nextEpisode.id)
    }

    /// The shared teardown behind both `close()` and `advanceToNextEpisode()`
    /// — cancels the auto-hide countdown, unlocks rotation (a player-only
    /// affordance; leaving it engaged past this point would leave the rest
    /// of the app stuck in whatever orientation the player happened to be
    /// locked to), reports this session's outcome and stops the same way
    /// either path needs to, then dismisses. `nextItemID`, when given, is
    /// handed to `onRequestNextItem` right before that dismiss — see its
    /// doc comment for why `ShowDetailView` only actually opens it once
    /// this dismiss reaches `onDismiss`, not synchronously here.
    ///
    /// Also where the close-vs-auto-advance race found live (2026-08-17)
    /// is closed: `dismissNextUp()` runs *before* the `await viewModel.stop()`
    /// below, which reports playback stopped over the network and can
    /// suspend long enough for a queued `onTimeUpdate` to land in the
    /// meantime (`nextUpSecondsRemaining`'s own doc comment documents the
    /// engine's clock overshooting `duration` at end-of-stream). Without
    /// this, that stray tick could push `nextUpSecondsRemaining` to exactly
    /// `0` *while a plain `close()` was already mid-flight*, firing
    /// `PlayerView`'s auto-advance `.onChange` concurrently and re-opening
    /// the next episode despite the user having tapped close — the same
    /// protection `dismissNextUp()` already gives the Cancel button, now
    /// covering every exit path instead of just one.
    private func tearDown(nextItemID: String? = nil) async {
        autoHideTask?.cancel()
        if isRotationLocked {
            RotationLock.unlock()
        }
        viewModel?.dismissNextUp()
        // Captured before `stop()` (which reports this same `currentTime` to
        // the server) and fired before `dismiss()`, so whichever detail page
        // presented this already has it applied by the time its own
        // `.fullScreenCover(onDismiss:)` fires — see `PlaybackSessionOutcome`'s
        // doc comment for why this exists at all.
        if let viewModel {
            onPlaybackEnded?(PlaybackSessionOutcome(
                itemID: itemID, positionSeconds: viewModel.currentTime, durationSeconds: viewModel.duration
            ))
        }
        await viewModel?.stop()
        if let nextItemID {
            onRequestNextItem?(nextItemID)
        }
        dismiss()
    }
}
