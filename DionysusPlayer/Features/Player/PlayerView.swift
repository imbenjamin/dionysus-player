import SwiftUI

/// Full-screen playback presented over whatever screen initiated it.
/// Renders AetherEngine's video surface with a custom transport-controls
/// overlay.
struct PlayerView: View {
    let itemID: String
    var startFromBeginning: Bool = false
    var mediaSourceID: String? = nil
    /// Fired from `close()` with this session's final position — see
    /// `PlaybackSessionOutcome`'s own doc comment for why. `nil` (the
    /// default) for any presentation that doesn't need it.
    var onPlaybackEnded: ((PlaybackSessionOutcome) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlayerViewModel?
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
    /// Pending "fade the controls out" work item — armed by `scheduleAutoHide()`
    /// whenever playback is actually running, cancelled the moment it isn't.
    @State private var autoHideTask: Task<Void, Never>?

    /// `.compact` is iPhone's landscape signal (see `HeroRailView.isLandscape`
    /// for the same check/caveat: this stays `.regular` in both orientations
    /// on iPad, so the zoom gestures below are effectively iPhone-only —
    /// acceptable here since an iPad's video area rarely fills the whole
    /// screen either way, unlike an iPhone in landscape).
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

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
                    onInteract: scheduleAutoHide
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

                if let errorMessage = viewModel.errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await viewModel.start() }
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
        // (paused, loading, seeking, buffering, ended, failed) both cancels
        // any pending fade and forces them back on screen. That covers not
        // just "don't hide while paused", but also things like a mid-scrub
        // `.seeking`/`.buffering` spell landing right as a stale timer was
        // about to fire, or the controls having been auto-hidden just
        // before the user paused some other way (e.g. a route change).
        .onChange(of: viewModel?.state) { _, newState in
            guard newState == .playing else {
                autoHideTask?.cancel()
                withAnimation(Self.fadeInAnimation) { showControls = true }
                return
            }
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
    }

    /// The single-tap "show/hide controls" behavior this overlay always
    /// had, now reached only once a double tap has failed to materialize —
    /// see the surface's `.gesture(...)` doc comment.
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
        guard showControls, !isShowingTrackPicker, viewModel?.state == .playing else { return }
        autoHideTask = Task {
            try? await Task.sleep(for: Self.autoHideDelay)
            guard !Task.isCancelled else { return }
            withAnimation(Self.fadeOutAnimation) { showControls = false }
        }
    }

    private func setUpIfNeeded() async {
        guard viewModel == nil, let client = appState.apiClient, let userID = appState.currentUser?.id else { return }
        guard let engine = try? AetherPlaybackEngine() else { return }
        let newViewModel = PlayerViewModel(
            client: client, userID: userID, itemID: itemID, engine: engine,
            startFromBeginning: startFromBeginning, mediaSourceID: mediaSourceID
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
        autoHideTask?.cancel()
        // Rotation lock is a player-only affordance — leaving it engaged
        // past this point would leave the rest of the app (Home, a detail
        // page, ...) stuck in whatever orientation the player happened to
        // be locked to when the user backed out.
        if isRotationLocked {
            RotationLock.unlock()
        }
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
        dismiss()
    }
}
