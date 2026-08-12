import SwiftUI

/// Full-screen playback presented over whatever screen initiated it.
/// Renders AetherEngine's video surface with a custom transport-controls
/// overlay.
struct PlayerView: View {
    let itemID: String
    var startFromBeginning: Bool = false
    var mediaSourceID: String? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlayerViewModel?
    @State private var showControls = true
    @State private var showTrackSelection = false
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    /// Mirrors `RotationLock`'s app-wide state for the button's own icon —
    /// see `toggleRotationLock()`/`close()` for why this view is what keeps
    /// the two in sync rather than `PlayerControlsOverlay` reading
    /// `RotationLock` directly.
    @State private var isRotationLocked = false
    /// Pending "fade the controls out" work item — armed by `scheduleAutoHide()`
    /// whenever playback is actually running, cancelled the moment it isn't.
    @State private var autoHideTask: Task<Void, Never>?

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
                    .onTapGesture {
                        let isRevealing = !showControls
                        withAnimation(isRevealing ? Self.fadeInAnimation : Self.fadeOutAnimation) {
                            showControls.toggle()
                        }
                        scheduleAutoHide()
                    }

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
                    onClose: { Task { await close() } },
                    onShowTracks: { showTrackSelection = true },
                    isRotationLocked: isRotationLocked,
                    onToggleRotationLock: toggleRotationLock,
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
        .sheet(isPresented: $showTrackSelection) {
            if let viewModel {
                TrackSelectionSheet(viewModel: viewModel)
            }
        }
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
    }

    /// (Re)arms the 3-second auto-hide countdown, replacing any countdown
    /// already pending. A no-op — and clears any pending countdown — unless
    /// controls are actually showing and playback is actually running;
    /// callers (the reveal tap, every button/drag in
    /// `PlayerControlsOverlay`, and playback resuming) call this
    /// unconditionally on every interaction rather than checking those
    /// themselves, so this is the one place that decides whether a fade
    /// should happen at all.
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard showControls, viewModel?.state == .playing else { return }
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
        await viewModel?.stop()
        dismiss()
    }
}
