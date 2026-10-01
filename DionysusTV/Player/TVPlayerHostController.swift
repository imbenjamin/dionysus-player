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
final class TVPlayerHostController: AVPlayerViewController {
    private let session: TVPlaybackSession
    private let engine: PlaybackEngine
    private let chrome = TVTransportChrome()
    private var viewModel: PlayerViewModel { session.viewModel }

    private var aetherView: AetherPlayerView?
    private var isAetherViewBound = false
    private var overlayHost: UIHostingController<TVTransportOverlay>?
    private var ourRecognizers: [UIGestureRecognizer] = []
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: PlayerViewModel, engine: PlaybackEngine) {
        self.session = TVPlaybackSession(viewModel: viewModel)
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // The engine is the only display-criteria writer (AetherEngine's "Host
        // setup on tvOS"): AVKit's automatic criteria race it for HDR HLS.
        appliesPreferredDisplayCriteriaAutomatically = false

        if let aether = engine as? AetherPlaybackEngine {
            bindToAVKit(aether)
        } else {
            showFakeSurface()
        }

        let overlay = UIHostingController(rootView: TVTransportOverlay(viewModel: viewModel, chrome: chrome))
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        overlay.view.frame = view.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(overlay)
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)
        overlayHost = overlay

        // Every handled press shows the transport; Select does nothing else.
        addPress(.select) { [weak self] in self?.chrome.poke() }
        addPress(.playPause) { [weak self] in self?.togglePlayPause() }
        addPress(.leftArrow) { [weak self] in self?.skip(by: -10) }
        addPress(.rightArrow) { [weak self] in self?.skip(by: 10) }
        addPress(.menu) { [weak self] in self?.close() }
    }

    /// Keyboard keys with no remote press of their own (`TVKeyboardCommand`).
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = presses
        for press in presses {
            guard let keyCode = press.key?.keyCode, let command = TVKeyboardCommand(keyCode: keyCode) else { continue }
            switch command {
            case .playPause: togglePlayPause()
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
        guard !session.hasEnded else { return dismiss(animated: true) }
        // The transport is up already; its fade starts with playback
        // (`TVTransportChrome.playbackStateChanged`), not here.
        session.begin()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // AVKit rebuilds parts of its chrome as the item changes; keep it hidden.
        hideAVKitChrome(in: view)
        if let overlay = overlayHost?.view { view.bringSubviewToFront(overlay) }
    }

    // MARK: - Surfaces

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

    private func togglePlayPause() {
        viewModel.togglePlayPause()
        chrome.poke()
    }

    private func skip(by seconds: TimeInterval) {
        let target = max(0, min(viewModel.duration, viewModel.currentTime + seconds))
        viewModel.seek(to: target)
        chrome.poke()
    }

    /// Ends the session before dismissing, in any state, `.loading` included.
    /// UIKit ignores a dismiss while the presentation is still animating, so
    /// one pressed then is left to `viewDidAppear`.
    func close() {
        session.end()
        guard !isBeingPresented else { return }
        dismiss(animated: true)
    }

    private func addPress(_ type: UIPress.PressType, _ action: @escaping () -> Void) {
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

