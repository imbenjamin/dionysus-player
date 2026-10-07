import AVKit
import AetherEngine
import Combine
import SwiftUI
import UIKit

/// The Apple TV player: an `AVPlayerViewController` with AVKit's chrome and
/// gestures switched off, so the system integration comes from AVKit (Now
/// Playing, audio routing, Atmos) while the transport is ours. This is the
/// integration AetherEngine's "Host setup on tvOS" describes, and Sodalite's.
///
/// On the native route AVKit renders the engine's `AVPlayer`; on the software
/// route there is no `AVPlayer`, so the engine's own `AetherPlayerView` does.
/// `TVPlayerSurfacePolicy` decides which, on every route change.
///
/// Under the UI-test harness the engine is a fake with no `AVPlayer` and no
/// Aether view, so nothing is bound to AVKit and its SwiftUI surface is shown
/// instead.
final class TVPlayerHostController: AVPlayerViewController, TVPlayerPresentation {
    private var session: TVPlaybackSession
    private var viewModel: PlayerViewModel { session.viewModel }
    private var engine: PlaybackEngine { viewModel.engine }
    private let input = TVPlayerInput()
    private var swipeGate = TVSwipeGate()

    private var aetherView: AetherPlayerView?
    private var isAetherViewBound = false
    private var fakeSurface: UIHostingController<AnyView>?
    private var overlayHost: UIHostingController<TVPlayerOverlay>?
    private var ourRecognizers: [UIGestureRecognizer] = []
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: PlayerViewModel) {
        session = TVPlaybackSession(viewModel: viewModel)
        super.init(nibName: nil, bundle: nil)
        input.context = { [weak self] in
            guard let self else { return TVPlayerContext() }
            return TVPlayerContext(viewModel: self.viewModel)
        }
        input.perform = { [weak self] commands in self?.run(commands) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // The engine is the only display-criteria writer (AetherEngine's "Host
        // setup on tvOS"): AVKit's automatic criteria race it for HDR HLS.
        appliesPreferredDisplayCriteriaAutomatically = false

        bindSurface()

        let overlay = UIHostingController(rootView: TVPlayerOverlay(viewModel: viewModel, input: input))
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        overlay.view.frame = view.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(overlay)
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)
        overlayHost = overlay

        // Every press goes to the input model, which decides what it means.
        addTap(.select) { [weak self] in self?.input.send(.select) }
        addTap(.playPause) { [weak self] in self?.input.send(.playPause) }
        addTap(.menu) { [weak self] in self?.input.send(.menu) }
        addTap(.upArrow) { [weak self] in self?.input.send(.up) }
        addTap(.downArrow) { [weak self] in self?.input.send(.down) }
        addArrow(.leftArrow, .left)
        addArrow(.rightArrow, .right)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)
        ourRecognizers.append(pan)
    }

    /// Remote presses our recognizers already turn into input. Passed up,
    /// `AVPlayerViewController` acts on them itself: it toggled playback on
    /// Play/Pause before our recognizer fired, so the model read the player
    /// as paused already, flashed Play for a pause and sent a toggle the
    /// engine ignored (Benjamin, on the Bedroom Apple TV, 2026-10-06).
    private static let swallowedPressTypes: Set<UIPress.PressType> = [.select, .playPause]

    private func forwardable(_ presses: Set<UIPress>) -> Set<UIPress> {
        presses.filter { !Self.swallowedPressTypes.contains($0.type) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = forwardable(presses)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = forwardable(presses)
        if !rest.isEmpty { super.pressesChanged(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = forwardable(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// Keyboard keys with no remote press of their own (`TVKeyboardCommand`).
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = forwardable(presses)
        for press in presses {
            guard let keyCode = press.key?.keyCode, let command = TVKeyboardCommand(keyCode: keyCode) else { continue }
            switch command {
            case .playPause: input.send(.playPause)
            }
            unhandled.remove(press)
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        suppressAVKitGestures(in: view)
        hideAVKitChrome(in: view)
        // Menu pressed during the presentation: its dismiss was deferred to here.
        guard !session.hasEnded else { return dismissReportingOutcome() }
        // The transport is up already; the input model times its fade from
        // playback starting, not from here.
        session.begin()
        input.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // AVKit rebuilds parts of its chrome as the item changes; keep it hidden.
        hideAVKitChrome(in: view)
        if let overlay = overlayHost?.view { view.bringSubviewToFront(overlay) }
    }

    // MARK: - Surfaces

    private func bindSurface() {
        if let aether = engine as? AetherPlaybackEngine {
            bindToAVKit(aether)
        } else {
            showFakeSurface()
        }
    }

    private func bindToAVKit(_ aether: AetherPlaybackEngine) {
        // Required before tvOS runs AVKit's Now Playing session, AirPods
        // detection and Atmos sync; the visible chrome is hidden separately.
        showsPlaybackControls = true
        playbackControlsIncludeInfoViews = false
        contextualActions = []

        let aetherView = AetherPlayerView()
        let surfaceHost = contentOverlayView ?? view!
        aetherView.frame = surfaceHost.bounds
        aetherView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surfaceHost.insertSubview(aetherView, at: 0)
        self.aetherView = aetherView

        let hostEngine = aether.hostEngine
        // Every emission, not just the first: an audio-track reload re-emits,
        // and an escalation moves native to software mid-session.
        hostEngine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in self?.apply(avPlayer: avPlayer, hostEngine: hostEngine) }
            .store(in: &cancellables)
        hostEngine.$currentAVPlayerItem
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.stampExternalMetadata(on: item) }
            .store(in: &cancellables)
    }

    private func apply(avPlayer: AVPlayer?, hostEngine: AetherEngine) {
        guard let aetherView else { return }
        let surface = TVPlayerSurfacePolicy.surface(nativePlayerAvailable: avPlayer != nil)
        if surface.avKitRendersPlayer, let avPlayer {
            player = avPlayer
            stampExternalMetadata(on: avPlayer.currentItem)
        } else {
            // Left set, AVKit draws a spinner over the software route's frames.
            player = nil
        }
        // Hidden, not merely unbound: on the native route the view's opaque
        // layer otherwise sits over AVKit's video, leaving sound, a display
        // mode switch and a black picture (found in the spike).
        aetherView.isHidden = !surface.engineViewVisible
        if surface.engineViewVisible, !isAetherViewBound {
            hostEngine.bind(view: aetherView)
            isAetherViewBound = true
        } else if !surface.engineViewVisible, isAetherViewBound {
            hostEngine.unbind(view: aetherView)
            isAetherViewBound = false
        }
    }

    private func showFakeSurface() {
        showsPlaybackControls = false
        let surface = UIHostingController(rootView: engine.makeSurface())
        surface.view.frame = view.bounds
        surface.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(surface)
        view.insertSubview(surface.view, at: 0)
        surface.didMove(toParent: self)
        fakeSurface = surface
    }

    /// AVKit's Now Playing card reads the item's `externalMetadata`.
    private func stampExternalMetadata(on item: AVPlayerItem?) {
        guard let item, let title = viewModel.item?.railTitle else { return }
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .commonIdentifierTitle
        metadata.value = title as NSString
        metadata.extendedLanguageTag = "und"
        item.externalMetadata = [metadata]
    }

    // MARK: - Remote

    private func run(_ commands: [TVPlayerCommand]) {
        TVPlayerCommandRunner(
            viewModel: viewModel,
            close: { [weak self] in self?.close() },
            playNext: { [weak self] in self?.advanceToNextItem() }
        ).run(commands)
    }

    /// Builds the player for another item, for Next Up. Set by
    /// `TVPlayerPresenter`, which holds the client, user and queue.
    var makeViewModel: ((String) -> PlayerViewModel?)?

    /// Play Now, or the countdown reaching zero: the next item plays in this
    /// player, without dismissing (spec, The host). The finished item is
    /// reported as iOS reports it, so Home and the page beneath are current.
    private func advanceToNextItem() {
        guard let next = viewModel.nextEpisode, let nextViewModel = makeViewModel?(next.id) else { return close() }
        // Before `end()`, as iOS's `tearDown` does: a late time update during
        // the stop could otherwise reach zero again and advance twice.
        viewModel.dismissNextUp()
        if let outcome = session.end() {
            pendingOutcome = outcome
            RecentPlaybackBroadcaster.shared.record(outcome)
        }
        // While `session` still holds the old view model, so `engine` is the
        // old engine.
        unbindSurface()
        session = TVPlaybackSession(viewModel: nextViewModel)
        input.reset()
        bindSurface()
        overlayHost?.rootView = TVPlayerOverlay(viewModel: nextViewModel, input: input)
        session.begin()
    }

    private func unbindSurface() {
        cancellables.removeAll()
        if let aetherView {
            if isAetherViewBound, let aether = engine as? AetherPlaybackEngine {
                aether.hostEngine.unbind(view: aetherView)
            }
            aetherView.removeFromSuperview()
        }
        aetherView = nil
        isAetherViewBound = false
        player = nil
        if let fakeSurface {
            fakeSurface.willMove(toParent: nil)
            fakeSurface.view.removeFromSuperview()
            fakeSurface.removeFromParent()
        }
        fakeSurface = nil
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            swipeGate.began()
        case .changed:
            let inputs = swipeGate.changed(
                translation: pan.translation(in: view), velocity: pan.velocity(in: view),
                width: view.bounds.width, scrubs: input.swipeScrubs
            )
            inputs.forEach(input.send)
        case .ended, .cancelled, .failed:
            swipeGate.ended().forEach(input.send)
        default:
            break
        }
    }

    /// Told where playback stopped, after the player has gone, so the page
    /// beneath can show it at once instead of waiting on the server.
    var onClose: (@MainActor (PlaybackSessionOutcome) -> Void)?
    private var pendingOutcome: PlaybackSessionOutcome?

    /// Ends the session before dismissing, in any state, `.loading` included.
    /// UIKit ignores a dismiss while the presentation is still animating, so
    /// one pressed then is left to `viewDidAppear`.
    func close() {
        input.stop()
        viewModel.dismissNextUp()
        if let outcome = session.end() {
            pendingOutcome = outcome
            // As iOS's `PlayerView` does: Home has no other way to learn it.
            RecentPlaybackBroadcaster.shared.record(outcome)
        }
        guard !isBeingPresented else { return }
        dismissReportingOutcome()
    }

    private func dismissReportingOutcome() {
        dismiss(animated: true) { [onClose, pendingOutcome] in
            if let pendingOutcome { onClose?(pendingOutcome) }
        }
    }

    /// Left and Right report down and up, so the model can tell a press from
    /// a hold. A long-press recognizer with no minimum is UIKit's way to get
    /// both edges of a remote press.
    private func addArrow(_ type: UIPress.PressType, _ direction: TVDirection) {
        let recognizer = UILongPressGestureRecognizer(
            target: self, action: direction == .left ? #selector(leftArrowChanged(_:)) : #selector(rightArrowChanged(_:))
        )
        recognizer.minimumPressDuration = 0
        recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
        view.addGestureRecognizer(recognizer)
        ourRecognizers.append(recognizer)
    }

    @objc private func leftArrowChanged(_ recognizer: UILongPressGestureRecognizer) { arrowChanged(recognizer, .left) }
    @objc private func rightArrowChanged(_ recognizer: UILongPressGestureRecognizer) { arrowChanged(recognizer, .right) }

    private func arrowChanged(_ recognizer: UILongPressGestureRecognizer, _ direction: TVDirection) {
        switch recognizer.state {
        case .began: input.send(.arrowDown(direction))
        case .ended, .cancelled, .failed: input.send(.arrowUp(direction))
        default: break
        }
    }

    private func addTap(_ type: UIPress.PressType, _ action: @escaping () -> Void) {
        let recognizer = PressRecognizer(action: action)
        recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
        view.addGestureRecognizer(recognizer)
        ourRecognizers.append(recognizer)
    }

    /// Switches off every recognizer AVKit installed, leaving ours.
    private func suppressAVKitGestures(in root: UIView) {
        let ours = Set(ourRecognizers.map(ObjectIdentifier.init))
        func walk(_ view: UIView) {
            if view === overlayHost?.view || view === aetherView { return }
            view.gestureRecognizers?.forEach { if !ours.contains(ObjectIdentifier($0)) { $0.isEnabled = false } }
            view.subviews.forEach(walk)
        }
        walk(root)
    }

    /// Hides AVKit's chrome by runtime class name (Sodalite's approach). This is
    /// the fragile part of the pattern: it keys off private view class names,
    /// which a tvOS release can rename.
    private func hideAVKitChrome(in root: UIView) {
        func walk(_ view: UIView) {
            if view === overlayHost?.view || view === aetherView || view === contentOverlayView { return }
            let name = String(describing: type(of: view))
            if ["Controls", "Transport", "Chrome", "Info", "Focus", "Menu"].contains(where: name.contains) {
                view.alpha = 0
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
    }
}

/// One remote press type, as a closure.
private final class PressRecognizer: UITapGestureRecognizer {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fire))
    }

    @objc private func fire() { action() }
}

