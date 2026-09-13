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
    /// An explicit start position, from a Chapters rail tap. Reuses
    /// `PlayerViewModel.start(resumeSeconds:)`'s override, which already beats
    /// the saved resume position, rather than adding a second mechanism.
    ///
    /// The first chapter starts at exactly `0`, which `start(resumeSeconds:)`
    /// doesn't honour, so a Chapter 1 tap would fall through to the saved
    /// position. `setUpIfNeeded()` therefore also forces `startFromBeginning`
    /// whenever this is non-nil — what a chapter deep link means anyway.
    var startSeconds: TimeInterval? = nil
    /// Fired from `close()` with this session's final position (see
    /// `PlaybackSessionOutcome`). `nil` for a presentation that doesn't need it.
    var onPlaybackEnded: ((PlaybackSessionOutcome) -> Void)? = nil
    /// Fired with the next item's id when `NextUpOverlay` advances, by its Play
    /// Now button or its countdown, just before this view dismisses. `nil` for
    /// presentations with no next item: `PlayerViewModel.nextEpisode` resolves
    /// only for Show content or a non-empty `playbackQueue`.
    ///
    /// Callers stash the id in local `@State` rather than re-pointing
    /// `playbackRequest` at it: setting an already-presented
    /// `.fullScreenCover(item:)`'s bound value while still presented doesn't
    /// re-present reliably, and leaves a wrong, unplayable item on screen.
    /// `playbackRequest` is set from `onDismiss`, once the cover has gone through
    /// `nil` — the path every ordinary Play tap takes.
    var onRequestNextItem: ((String) -> Void)? = nil
    /// Non-nil plays this local copy instead of fetching `itemID` over the
    /// network. `itemID` should still be `downloadedItem.itemID`.
    var downloadedItem: DownloadedItem? = nil
    /// A Playlist's ordered, audio-filtered members; empty for every ordinary
    /// presentation. `PlaylistDetailView` passes the same array to every
    /// presentation it makes, so playback advances by walking this one array
    /// forward wherever it started. `PlayerViewModel.playbackQueue` covers how it
    /// takes over "what's next" resolution.
    var playbackQueue: [MediaItem] = []

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    /// Gates `scheduleAutoHide()`. The 3-second auto-hide is hostile to
    /// VoiceOver: it isn't enough time to swipe to a control and double-tap it
    /// before the row fades and goes `.accessibilityHidden`. Controls never
    /// auto-hide under VoiceOver, staying dismissible by blank-space tap.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var viewModel: PlayerViewModel?
    /// Set when `setUpIfNeeded()`'s engine construction throws. Swallowing it
    /// left this view on `LoadingView()` forever, with no `viewModel` to hold an
    /// `errorMessage` and no sign anything had gone wrong.
    @State private var setupError: String?
    @State private var showControls = true
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    /// Whether the track picker is showing. Lives here rather than in
    /// `PlayerControlsOverlay` so `scheduleAutoHide()` can see it: otherwise the
    /// timer fades the whole controls row, picker included, out from under the
    /// user reading it.
    @State private var isShowingTrackPicker = false
    /// Whether `ChapterPickerOverlay` is showing, here for the same reason
    /// `isShowingTrackPicker` is.
    @State private var isShowingChapterPicker = false
    /// Mirrors `RotationLock`'s app-wide state for the button's icon;
    /// `toggleRotationLock()` and `close()` keep the two in sync.
    @State private var isRotationLocked = false
    /// Mirrors the engine's zoom mode, as `isRotationLocked` mirrors
    /// `RotationLock`. Driven by `handleDoubleTap()` and `pinchZoomGesture`, and
    /// reset to `.fit` on leaving landscape.
    @State private var zoomMode: VideoZoomMode = .fit
    /// Whether the window is wider than tall: the gate for every zoom affordance.
    ///
    /// Window geometry rather than `isLandscape`, which is iPhone's landscape
    /// signal and stays `.regular` on iPad in both orientations — gating on it
    /// disabled zoom across iPad, leaving letterboxed content unable to fill the
    /// screen.
    ///
    /// `.onGeometryChange` rather than `interfaceOrientation`: it is this
    /// codebase's standard, republishes itself, can't disagree with the UI under
    /// rotation lock, and under Split View describes the window the video
    /// occupies. Unlike a `GeometryReader` it reads the resolved size without
    /// proposing one, avoiding the zero-size failures the picker sizing
    /// documents.
    @State private var isLandscapeWindow = false
    /// Whether `PlaybackStatsOverlay` is showing. Unlike `showControls` it has no
    /// auto-hide: a plain toggle only the info button flips.
    @State private var showPlaybackStats = false
    /// Guards `advanceToNextItem()` against re-firing while its
    /// `await viewModel.stop()` is in flight: the
    /// `.onChange(of: nextUpSecondsRemaining)` trigger could otherwise fire again
    /// on an intermediate render before `onRequestNextItem` swaps this screen out.
    @State private var isAdvancingToNextEpisode = false
    /// The pending fade-out, armed by `scheduleAutoHide()` while playback runs
    /// and cancelled the moment it doesn't.
    @State private var autoHideTask: Task<Void, Never>?
    /// True from a skip tap until playback resumes, suppressing the
    /// `viewModel?.state` `.onChange` below from forcing the transport chrome
    /// back on screen — which a skip's own `.seeking` spell would otherwise
    /// trigger like any stall. `SkipSegmentOverlay` shows its own spinner instead.
    @State private var isSkippingSegment = false
    /// Invalidates a stale `isSkippingSegment` reset. The safety-net `Task` below
    /// exists because a very small skip may never visibly enter `.seeking`, and
    /// needs this token so an earlier skip's timeout can't clear suppression for
    /// a later one still in progress.
    @State private var skipSegmentGeneration = 0

    /// "Is this window short", not "is it landscape": `.compact` is iPhone's
    /// landscape signal and stays `.regular` on iPad either way. The zoom
    /// affordances use `isLandscapeWindow`; only height-sensitive code reads this.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Drives `SkipSegmentOverlay`'s spinner. `isSkippingSegment` stays true for
    /// the whole suppression window, including after playback resumes, so this
    /// also requires a buffering-like engine state — matching
    /// `PlayerControlsOverlay.isBuffering` — and a near-instant skip flashes no
    /// spinner at all.
    private var isSkipBuffering: Bool {
        guard isSkippingSegment else { return false }
        switch viewModel?.state {
        case .loading, .seeking, .buffering, .reconnecting: return true
        default: return false
        }
    }

    /// How long the controls sit idle before fading, once armed. Applies only
    /// while playback is running.
    private static let autoHideDelay: Duration = .seconds(3)
    /// Asymmetric: fading out happens after idle time and can be leisurely, while
    /// revealing answers a tap and must feel immediate.
    private static let fadeOutAnimation: Animation = .easeInOut(duration: 0.5)
    private static let fadeInAnimation: Animation = .easeInOut(duration: 0.1)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let viewModel {
                viewModel.engine.makeSurface()
                    .ignoresSafeArea()
                    // `exclusively(before:)` holds the single tap until the
                    // double-tap window passes, the disambiguation a
                    // `UITapGestureRecognizer` pair needs `require(toFail:)` for.
                    // Without it both taps register as sequential single taps,
                    // showing then re-hiding controls instead of toggling zoom.
                    .gesture(
                        TapGesture(count: 2)
                            .onEnded { handleDoubleTap() }
                            .exclusively(before: TapGesture(count: 1).onEnded { handleSingleTap() })
                    )
                    // Simultaneous rather than exclusive with the taps above: a
                    // two-finger pinch can't be confused with either.
                    .simultaneousGesture(pinchZoomGesture)

                // Above the video surface, below the transport chrome, and
                // visible independent of `showControls` — subtitles aren't
                // controls and shouldn't fade with them. Its bottom clearance
                // animates in step with the fade instead.
                SubtitleOverlayView(viewModel: viewModel, zoomMode: zoomMode, controlsVisible: showControls)
                    .ignoresSafeArea()

                // Between the video surface and `PlayerControlsOverlay`. Always
                // mounted, with `showPlaybackStats` driving its internal opacity
                // rather than inserting and removing it: a mount toggle here
                // visibly shifted the rest of the player UI.
                PlaybackStatsOverlay(viewModel: viewModel, zoomMode: zoomMode, isVisible: showPlaybackStats)

                // Always mounted, animating `.opacity` on a permanent view rather
                // than a conditional `.transition(.opacity)`. This overlay reads
                // `viewModel.currentTime`, which ticks ~10 times a second, and
                // each tick forces an un-animated render pass. Those passes carry
                // no transaction, so they beat an in-flight removal animation:
                // the fade never got more than a frame or two in before snapping
                // back to fully rendered, reading as an instant cut rather than a
                // ~0.5s fade. A plain `.opacity` is interpolated across whatever
                // transaction last changed it, and an unrelated re-render re-reads
                // the interpolated value instead of resetting it.
                PlayerControlsOverlay(
                    viewModel: viewModel,
                    isScrubbing: $isScrubbing,
                    scrubTime: $scrubTime,
                    isShowingTrackPicker: $isShowingTrackPicker,
                    isShowingChapterPicker: $isShowingChapterPicker,
                    onClose: { Task { await close() } },
                    isRotationLocked: isRotationLocked,
                    onToggleRotationLock: toggleRotationLock,
                    isPlaybackStatsVisible: showPlaybackStats,
                    onTogglePlaybackStats: { showPlaybackStats.toggle() },
                    zoomMode: zoomMode,
                    onToggleZoomMode: { setZoomMode(zoomMode.toggled) },
                    isLandscapeWindow: isLandscapeWindow,
                    onEnterPictureInPicture: { viewModel.startPictureInPicture() },
                    onInteract: scheduleAutoHide,
                    onDismissControls: dismissControls
                )
                .opacity(showControls ? 1 : 0)
                // Disabled the instant `showControls` flips rather than when the
                // fade finishes: a still-fading but logically hidden overlay
                // would keep intercepting the taps meant to reveal it, its
                // background gradient hit-testing like its buttons do.
                .allowsHitTesting(showControls)
                // Keeps VoiceOver off buttons that are present but faded out.
                .accessibilityHidden(!showControls)

                // Above `PlayerControlsOverlay` and, unlike it, not gated on
                // `showControls`: complementary to the transport chrome rather
                // than part of it, so it stays interactive either way.
                NextUpOverlay(
                    nextEpisode: viewModel.nextEpisode,
                    secondsRemaining: viewModel.nextUpSecondsRemaining,
                    totalSeconds: viewModel.nextUpTotalCountdownSeconds,
                    onPlayNow: { Task { await advanceToNextItem() } },
                    onCancel: { viewModel.dismissNextUp() }
                )

                // The same bottom-trailing slot and always-mounted treatment as
                // `NextUpOverlay`; the two never compete for it.
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

                // VoiceOver-only: an always-reachable way back to the transport
                // chrome once hidden. The surface's tap-to-reveal gesture isn't a
                // reliable path for VoiceOver, which swipes between focusable
                // elements rather than exploring screen coordinates.
                //
                // Unmounted rather than `.accessibilityHidden` when VoiceOver is
                // off, and never gated on `showControls` — the point is that it
                // stays reachable exactly when everything else is hidden.
                //
                // Vertically centred on the leading edge, the one spot clear of
                // everything else in either `showControls` state: `topSection`
                // occupies the top, `scrubberBar` spans the bottom including its
                // leading timestamp, and the transport row sits centred between
                // them. That keeps it at a predictable point in VoiceOver's swipe
                // order whatever else is visible.
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
                    // `ErrorStateView`/`OfflineStateView` carry no opaque
                    // background: every other screen using them replaces a plain
                    // content region with nothing behind it. Here the transport
                    // chrome is still mounted underneath and bled through every
                    // gap around the icon and buttons.
                    //
                    // A dimming scrim — which also blocks taps, a filled `Color`
                    // hit-testing across its frame — plus a bounded opaque card
                    // gives the error a modal presentation, in the same panel
                    // language the track picker uses.
                    //
                    // The dim is light, matching a standard iOS modal scrim: the
                    // card's own fill and border is what reads as on top, and
                    // blacking out the always-present toolbar underneath would
                    // crush something that stayed legible before.
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()

                        // A terminal failure while already offline — the common
                        // LAN-drop case, where the same outage kills
                        // `reportPlaybackProgress` and so keeps
                        // `ConnectivityMonitor` current — gets the shared offline
                        // screen with a retry that resumes in place.
                        //
                        // Otherwise branch on `failureCategory`. `.refused` gets
                        // Close only, Retry being unable to fix an access refusal
                        // or undecodable content. `.rateLimited` and `.transient`
                        // keep Retry, both being worth retrying, and also get
                        // Close: a Retry-only dead end left no way out of the
                        // player at all.
                        Group {
                            if ConnectivityMonitor.shared.isOffline {
                                // No `.tint` override: `OfflineStateView`'s
                                // primary action is `.borderedProminent`, whose
                                // tint is its fill rather than its label colour,
                                // so forcing white gave a white-on-white button
                                // with no visible label. The default accent
                                // contrasts fine against this dark card.
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
                                // `.bordered`, so tint colours only the label and
                                // border, making white the right fix here.
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
                        // Those views' icon and message use `.secondary`, which
                        // assumes it paints onto the system appearance — true
                        // everywhere else they are used. This card is always
                        // dark, so in Light mode `.secondary` resolved to a
                        // mid-gray meant for a light background and was nearly
                        // invisible. Forcing the subtree's colour scheme makes it
                        // resolve to its dark value, matching what the card
                        // always is.
                        //
                        // The buttons' `.tint(.white)` stays per-branch above: a
                        // blanket override here would white out
                        // `OfflineStateView`'s prominent button.
                        .colorScheme(.dark)
                        // Caps growth to a bounded card rather than the
                        // full-screen fill each view's body requests, nested
                        // `.frame` proposals bounding the infinite one inside.
                        // `.fixedSize` on the vertical axis stops it stretching
                        // to the scrim's height, so the card hugs its content.
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
        // Feeds every zoom affordance. On the whole player rather than the video
        // surface, whose frame is what zooming changes — circular otherwise.
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height }
            action: { isLandscapeWindow = $0 }
        .task { await setUpIfNeeded() }
        // Controls fade only while `.playing`; every other state cancels a
        // pending fade and forces them back on screen. That covers a mid-scrub
        // `.seeking` spell landing as a stale timer was about to fire, and
        // controls auto-hidden just before a pause from elsewhere, such as a
        // route change.
        //
        // Skipped while PiP is active: a state change reachable from there, such
        // as pausing from the system overlay, would force the transport chrome
        // over `PictureInPictureOverlay`'s placeholder, with nothing to hide it
        // again — the PiP `onChange` below fires only on a transition of
        // `isPictureInPictureActive`.
        //
        // Skipped while `isSkippingSegment` too: a skip's own `.seeking` spell
        // shouldn't reveal the chrome the way a user-initiated pause does, and
        // `SkipSegmentOverlay` shows its own spinner instead. Chrome already
        // visible when Skip was tapped is left as it was.
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
        // Zoom is landscape-only, and both gestures are gated on
        // `isLandscapeWindow`, so leaving landscape with `.fill` active would
        // strand a cropped portrait video with no way to un-zoom it.
        .onChange(of: isLandscapeWindow) { _, landscape in
            guard !landscape else { return }
            setZoomMode(.fit)
        }
        // Opening a picker cancels any pending fade, `scheduleAutoHide()`
        // blocking a reschedule while one is showing; closing it starts a fresh
        // countdown, the same full `autoHideDelay` every other interaction gets.
        .onChange(of: isShowingChapterPicker) { _, _ in
            scheduleAutoHide()
        }
        .onChange(of: isShowingTrackPicker) { _, _ in
            scheduleAutoHide()
        }
        // The automatic half of the Up Next countdown: reaching 0 advances on its
        // own, and Play Now or Cancel preempt it.
        .onChange(of: viewModel?.nextUpSecondsRemaining) { _, secondsRemaining in
            guard secondsRemaining == 0 else { return }
            Task { await advanceToNextItem() }
        }
        // Entering PiP from the in-app button leaves the app foregrounded, and
        // nothing else `showControls` reacts to changes, so without this the
        // transport chrome sat on top of `PictureInPictureOverlay`'s
        // placeholder. No `withAnimation` on the way in: PiP is instant, so the
        // controls should vanish with it rather than lag mid-fade. Leaving PiP
        // restores them like any other interaction.
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
        // No screen-root identifier. On this view's outermost container,
        // `.accessibilityIdentifier` propagated onto every descendant — 22
        // elements all reporting `player.root`, overwriting each control's own.
        // The same modifier on `HomeView` doesn't, so it is specific to being
        // presented in a `.fullScreenCover`. Tests identify this screen by its
        // close button.
    }

    /// Show/hide controls, reached only once a double tap has failed to
    /// materialize. In practice this only ever reveals:
    /// `PlayerControlsOverlay`'s full-bounds tap catcher claims every tap while
    /// `showControls` is true, so hiding goes through `dismissControls()`.
    private func handleSingleTap() {
        let isRevealing = !showControls
        withAnimation(isRevealing ? Self.fadeInAnimation : Self.fadeOutAnimation) {
            showControls.toggle()
        }
        scheduleAutoHide()
    }

    /// Toggles fit and fill, in landscape only and only while controls are
    /// hidden, so a double tap aimed at a button doesn't also zoom the video.
    private func handleDoubleTap() {
        guard isLandscapeWindow, !showControls else { return }
        setZoomMode(zoomMode.toggled)
    }

    /// Interchangeable with the double tap: pinching open zooms to `.fill`,
    /// closed to `.fit`. Not gated on `showControls`, a two-finger pinch being
    /// unconfusable with a tap on a control. A dead zone around 1.0 avoids
    /// flipping on the incidental magnification a light double-tap registers.
    private var pinchZoomGesture: some Gesture {
        MagnifyGesture()
            .onEnded { value in
                guard isLandscapeWindow, abs(value.magnification - 1) > 0.05 else { return }
                setZoomMode(value.magnification > 1 ? .fill : .fit)
            }
    }

    private func setZoomMode(_ mode: VideoZoomMode) {
        zoomMode = mode
        viewModel?.setZoomMode(mode)
    }

    /// Re-arms the auto-hide countdown, replacing any pending one. A no-op —
    /// clearing any pending countdown — unless controls are showing, playback is
    /// running, and no picker is up; without that last check, reading the
    /// picker's options fades the whole controls row, picker included.
    ///
    /// Callers invoke this unconditionally on every interaction rather than
    /// checking those themselves, so this is the one place deciding whether a
    /// fade happens.
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        #if DEBUG
        // A UI test drives these controls without VoiceOver, so the branch below
        // never fires and every assertion races the 3s fade.
        guard !UITestHarness.keepsPlayerControlsVisible else { return }
        #endif
        guard showControls, !isShowingTrackPicker, !isShowingChapterPicker,
              !voiceOverEnabled, viewModel?.state == .playing else { return }
        autoHideTask = Task {
            try? await Task.sleep(for: Self.autoHideDelay)
            guard !Task.isCancelled else { return }
            withAnimation(Self.fadeOutAnimation) { showControls = false }
        }
    }

    /// A blank-space tap inside `PlayerControlsOverlay` while it is showing. The
    /// same fade `scheduleAutoHide()`'s timer uses, triggered immediately, and
    /// cancels the pending countdown, which now has nothing to do.
    private func dismissControls() {
        autoHideTask?.cancel()
        withAnimation(Self.fadeOutAnimation) { showControls = false }
    }

    private func setUpIfNeeded() async {
        guard viewModel == nil, let client = appState.apiClient else { return }
        // Falls back to the stored credentials' userID so offline playback works
        // from a cold launch that resumed `.main` from a cached session.
        guard let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID else { return }
        let engine: PlaybackEngine
        do {
            engine = try PlaybackEngineFactory.make()
        } catch {
            Self.logger.error("AetherPlaybackEngine construction failed: \(error.localizedDescription, privacy: .public)")
            setupError = String(localized: "Couldn't start the video player.")
            return
        }
        let newViewModel = PlayerViewModel(
            client: client, userID: userID, itemID: itemID, engine: engine,
            // A chapter deep link must suppress the saved resume position
            // explicitly; `resumeSeconds` alone can't, a first chapter being `0`.
            startFromBeginning: startFromBeginning || startSeconds != nil, mediaSourceID: mediaSourceID,
            downloadedItem: downloadedItem, downloadStore: downloadedItem != nil ? appState.downloadManager.store : nil,
            playbackQueue: playbackQueue
        )
        viewModel = newViewModel
        await newViewModel.start(resumeSeconds: startSeconds)
    }

    /// Flips `RotationLock` and this view's mirror of it together.
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

    /// `NextUpOverlay`'s Play Now button and the countdown reaching zero.
    /// Guarded separately from `tearDown(nextItemID:)`, which `close()` also
    /// calls with no id to guard on.
    private func advanceToNextItem() async {
        guard let viewModel, let nextEpisode = viewModel.nextEpisode, !isAdvancingToNextEpisode else { return }
        isAdvancingToNextEpisode = true
        await tearDown(nextItemID: nextEpisode.id)
    }

    /// Shared teardown behind `close()` and `advanceToNextItem()`: cancels the
    /// auto-hide countdown, unlocks rotation — a player-only affordance that
    /// would otherwise strand the rest of the app in the player's orientation —
    /// reports this session's outcome, stops, and dismisses. A given
    /// `nextItemID` reaches `onRequestNextItem` just before that dismiss.
    ///
    /// `dismissNextUp()` runs before `await viewModel.stop()`, which reports
    /// playback stopped over the network and can suspend long enough for a queued
    /// `onTimeUpdate` to land — and the engine's clock overshoots `duration` at
    /// end-of-stream. That stray tick could push `nextUpSecondsRemaining` to `0`
    /// mid-`close()`, firing the auto-advance `.onChange` and re-opening the next
    /// episode despite the user tapping close.
    private func tearDown(nextItemID: String? = nil) async {
        autoHideTask?.cancel()
        if isRotationLocked {
            RotationLock.unlock()
        }
        viewModel?.dismissNextUp()
        // Captured before `stop()`, which reports the same `currentTime`, and
        // fired before `dismiss()`, so the presenting page has it applied by the
        // time its `.fullScreenCover(onDismiss:)` fires.
        if let viewModel {
            let outcome = PlaybackSessionOutcome(
                itemID: itemID, positionSeconds: viewModel.currentTime, durationSeconds: viewModel.duration
            )
            onPlaybackEnded?(outcome)
            // Broadcast unconditionally, not only when a presenter passes
            // `onPlaybackEnded`: `RecentPlaybackBroadcaster`'s separate consumer
            // has no other way to learn this outcome.
            RecentPlaybackBroadcaster.shared.record(outcome)
        }
        await viewModel?.stop()
        if let nextItemID {
            onRequestNextItem?(nextItemID)
        }
        dismiss()
    }
}
