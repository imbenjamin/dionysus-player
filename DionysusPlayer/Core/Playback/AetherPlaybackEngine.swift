import AVKit
import Combine
import Foundation
import MediaPlayer
import SwiftUI
import UIKit
import AetherEngine
import os

/// `PlaybackEngine` implemented on AetherEngine.
///
/// Adapts its Combine publishers and `TrackInfo`/`VideoFormat`/`PlaybackState`
/// shapes onto the app's smaller protocol, so feature code never touches
/// AetherEngine's types directly.
@MainActor
final class AetherPlaybackEngine: PlaybackEngine {
    private static let logger = Logger(subsystem: "com.dionysus.player", category: "AetherPlaybackEngine")

    private let engine: AetherEngine
    private var cancellables: Set<AnyCancellable> = []
    /// Repairs a paused session that AetherEngine's background grace-window
    /// teardown left with no pipeline to resume (see `observeAppLifecycle()`).
    private var didBecomeActiveObserver: NSObjectProtocol?
    /// The end state `recoverSessionIfNeeded(desiredState:)`'s in-flight reload
    /// applies once it resolves.
    private enum SessionRecoveryDesiredState { case play, pause }
    private var sessionRecoveryDesiredState: SessionRecoveryDesiredState = .pause
    private var sessionRecoveryTask: Task<Void, Never>?
    /// Set before `load(...)` re-throws a source-open, probe or route failure as
    /// `PlaybackLoadFailure`. AetherEngine also publishes a matching `.error` on
    /// `$playbackPhase` for the same failure, which would otherwise reach
    /// `PlayerViewModel` twice. Consumed by the next `.error` phase
    /// `observeEngine()` sees.
    private var suppressNextErrorPhase = false
    /// Guards the seek watchdog below — see `seek(to:)`.
    private var seekWatchdogTask: Task<Void, Never>?
    private var seekWatchdogGeneration = 0
    /// How long a seek may sit in `.seeking`/`.rebuffering` with the playhead
    /// stuck near the target before it counts as wedged rather than rebuffering
    /// — AetherEngine's backward-seek freeze (upstream issue #93), mitigated but
    /// not eliminated. An estimate, not a measured value.
    private static let seekWatchdogTimeout: TimeInterval = 8

    var onStateChange: ((PlaybackState) -> Void)?
    var onTimeUpdate: ((TimeInterval, TimeInterval) -> Void)?
    var onSubtitleCuesChange: (([SubtitleCueDisplay]) -> Void)?
    var onSourceTimeUpdate: ((TimeInterval) -> Void)?
    var onPictureInPicturePossibleChange: ((Bool) -> Void)?
    var onPictureInPictureActiveChange: ((Bool) -> Void)?

    /// Built around `engine.nativePlayerLayer`, so the native AVPlayer route
    /// only. Rebuilt from the `engine.$currentAVPlayer` sink below, which
    /// re-emits on every reload — when a stale layer needs replacing, or a
    /// session that has just gone native needs one at all.
    private var pipController: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    /// `AVPictureInPictureControllerDelegate` is `NSObjectProtocol`-bound, and
    /// conforming directly would cost this class its throwing argument-less
    /// `init()`, whose signature `NSObject.init()` occupies. A small proxy
    /// avoids retrofitting inheritance for one protocol.
    private let pipDelegateProxy = PictureInPictureDelegateProxy()

    private(set) var audioTracks: [PlaybackTrack] = []
    private(set) var subtitleTracks: [PlaybackTrack] = []
    private(set) var videoFormatDescription: String?

    /// Read off `engine`'s stored properties, which are set once per source.
    var videoNaturalSize: CGSize? {
        guard engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 else { return nil }
        return CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight))
    }

    private var selectedAudioTrackID: Int?
    private var selectedSubtitleTrackID: Int?
    /// Set once per `load(...)`, read by the `$audioTracks` subscription each
    /// time AetherEngine republishes the list.
    private var knownAtmosAudioTrackIndices: Set<Int> = []

    /// Bridges to AetherEngine's `videoGravity`, which drives whichever render
    /// layer is bound: `.resizeAspect` for `.fit`, `.resizeAspectFill` for
    /// `.fill`. Read back rather than mirrored in stored state, so it can't
    /// drift from what is applied.
    var zoomMode: VideoZoomMode {
        get { engine.videoGravity == .resizeAspectFill ? .fill : .fit }
        set { engine.videoGravity = newValue == .fill ? .resizeAspectFill : .resizeAspect }
    }

    /// Reads `engine`'s properties on every access rather than mirroring them:
    /// `PlaybackStatsOverlay` polls this a couple of times a second, which
    /// doesn't justify duplicating AetherEngine's bookkeeping.
    var stats: PlaybackStats {
        PlaybackStats(
            videoSize: engine.sourceVideoWidth > 0 ? "\(engine.sourceVideoWidth)×\(engine.sourceVideoHeight)" : nil,
            frameRate: engine.sourceVideoFrameRate.map { String(format: "%.3g fps", $0) },
            bitrate: engine.sourceVideoBitrate > 0 ? Self.formatBitrate(engine.sourceVideoBitrate) : nil,
            sourceColorFormat: Self.describeColorFormat(engine.sourceVideoFormat, dvProfile: engine.sourceDVProfile),
            displayColorFormat: Self.describeColorFormat(engine.videoFormat, dvProfile: nil),
            videoDecoder: engine.activeVideoDecoder,
            audioDecoder: engine.activeAudioDecoder,
            audioChannels: Self.describeChannels(engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }),
            backend: engine.playbackBackend.rawValue.capitalized,
            route: Self.describeVideoRoute(engine.videoRoute),
            // Native-only, per `PlaybackStats.bufferedSeconds`. On the software
            // backend `bufferedPosition` tracks the playhead rather than any
            // read-ahead, so diffing it against `currentTime` or `sourceTime`
            // only ever reads ~0.
            //
            // Prefers `loadedTimeRanges` where available: on the
            // `nativeRemoteHLS` route `bufferedPosition` sits permanently at
            // `sourceTime`, reading as a constant "Buffered: 0.0s". That route
            // has no local segment cache for its clock to measure — AVPlayer
            // buffers against the origin itself — which is why
            // `LoadOptions.forwardBufferSegments` is documented as ignored
            // there. Falls back to the `bufferedPosition` diff when no
            // AVPlayerItem exists.
            bufferedSeconds: engine.playbackBackend == .native
                ? (engine.currentAVPlayerItem.flatMap { Self.bufferedAheadSeconds(item: $0, currentTime: engine.sourceTime) }
                    ?? max(0, engine.bufferedPosition - engine.sourceTime))
                : nil,
            // `liveTelemetry`'s 1 Hz sampler runs for every session despite its
            // name. Its `cachedBytes` measures the same segment cache
            // `bufferedSeconds` reads above, so it is native-only for the same
            // reason.
            bufferedBytes: engine.liveTelemetry?.cachedBytes,
            currentTime: engine.currentTime,
            duration: engine.duration
        )
    }

    init() throws {
        self.engine = try AetherEngine()
        pipDelegateProxy.engine = self
        // Takes ownership of the system Now-Playing session on the native video
        // path. AetherEngine defaults this off for `AVPlayerViewController`
        // hosts, where AVKit owns Now-Playing; this app renders its own
        // transport chrome, so it is the custom-UI case meant to opt in. Must
        // precede `load()`.
        engine.ownsVideoNowPlayingSession = true
        observeEngine()
        observeAppLifecycle()
    }

    // `isolated deinit`: `didBecomeActiveObserver` is `@MainActor` state, which
    // a `nonisolated deinit` can't touch under Swift 6 strict concurrency.
    isolated deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    private func observeEngine() {
        // `$playbackPhase`, not the narrower `$state`: AetherEngine reports a
        // buffer underrun (`.rebuffering`) or a dropped source connection
        // (`.stalled`) while `state` stays `.playing`, so `state` alone can't
        // distinguish playing from "frames stopped, working on it". That left
        // `PlayerControlsOverlay.isBuffering` with nothing to key off when a
        // scrub landed somewhere that needed to rebuffer.
        //
        // The two bridge to separate app states (`.buffering` and
        // `.reconnecting`) so the UI can tell a healthy underrun from a dropped
        // connection, and so `PlayerViewModel` consults `ConnectivityMonitor`
        // only when a `.reconnecting` spell ends in `.failed`.
        engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                // Forward progress disarms the seek watchdog (see `seek(to:)`),
                // leaving it armed only while stuck on `.seeking`/`.rebuffering`.
                switch phase {
                case .seeking, .rebuffering: break
                default: self.seekWatchdogTask?.cancel()
                }
                let bridged: PlaybackState
                switch phase {
                case .idle:              bridged = .idle
                case .loading:           bridged = .loading
                case .playing:           bridged = .playing
                case .paused:            bridged = .paused
                case .seeking:           bridged = .seeking
                case .rebuffering:       bridged = .buffering
                case .stalled:           bridged = .reconnecting
                case .ended:             bridged = .ended
                case .error(let message):
                    // A source-open, probe or route failure both throws and
                    // publishes `.error`, and `load(...)` already re-threw it as
                    // `PlaybackLoadFailure`. Skipping it here keeps
                    // `PlayerViewModel` hearing it once. Any other `.error` — a
                    // session dying after load returned — never throws and
                    // still needs bridging.
                    if self.suppressNextErrorPhase {
                        self.suppressNextErrorPhase = false
                        return
                    }
                    bridged = .failed(PlaybackFailure(
                        message: message,
                        category: self.engine.errorInfo.map { Self.category(for: $0.kind) } ?? .transient
                    ))
                }
                MainActor.assumeIsolated {
                    self.onStateChange?(bridged)
                }
            }
            .store(in: &cancellables)

        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onTimeUpdate?(time, self.engine.duration)
                }
            }
            .store(in: &cancellables)

        // `engine.duration` settles from its own sink, independent of
        // `clock.$currentTime`. A paused session produces no ticks, so a
        // duration settling after the last one needs this bridge to arrive.
        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onTimeUpdate?(self.engine.currentTime, duration)
                }
            }
            .store(in: &cancellables)

        // Separate from `clock.$currentTime`: cues are stamped in source PTS,
        // which diverges from the AVPlayer-axis clock across producer restarts.
        engine.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sourceTime in
                MainActor.assumeIsolated {
                    self?.onSourceTimeUpdate?(sourceTime)
                }
            }
            .store(in: &cancellables)

        // AetherEngine emits cues but paints nothing. This is the only place
        // they cross into the app, normalized to `SubtitleCueDisplay` so
        // nothing else touches AetherEngine's subtitle types.
        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                MainActor.assumeIsolated {
                    self?.onSubtitleCuesChange?(cues.map(Self.normalize))
                }
            }
            .store(in: &cancellables)

        engine.$videoFormat
            .receive(on: DispatchQueue.main)
            .sink { [weak self] format in
                let description = Self.describe(format)
                MainActor.assumeIsolated {
                    self?.videoFormatDescription = description
                }
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.audioTracks = Self.normalize(
                        tracks, kind: .audio, selectedID: self.selectedAudioTrackID,
                        knownAtmosAudioTrackIndices: self.knownAtmosAudioTrackIndices
                    )
                }
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.subtitleTracks = Self.normalize(tracks, kind: .subtitle, selectedID: self.selectedSubtitleTrackID)
                }
            }
            .store(in: &cancellables)

        // Picks up the default track AetherEngine resolves at load, and any
        // engine-internal change after it, from `activeAudioTrackIndex`/
        // `activeSubtitleTrackIndex`. Without these, both selections stay `nil`
        // — no checkmark anywhere — from load until the first manual pick, even
        // though a default track is already playing.
        //
        // Independent of firing order against the `$audioTracks` subscriptions
        // above: whichever arrives second paints the checkmark, and either
        // order reaches the same result.
        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.selectedAudioTrackID = index
                    self.audioTracks = self.audioTracks.map { $0.selected($0.id == index) }
                }
            }
            .store(in: &cancellables)

        engine.$activeSubtitleTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.selectedSubtitleTrackID = index
                    self.subtitleTracks = self.subtitleTracks.map { $0.selected($0.id == index) }
                }
            }
            .store(in: &cancellables)

        // Re-emitted on every reload, which is exactly when
        // `engine.nativePlayerLayer` gains or replaces a layer, so it is the
        // signal to rebuild the PiP controller around the current one.
        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updatePictureInPictureController()
                    // Same signal: `engine.videoNowPlayingSession` exists only
                    // once a native host does, and a rebuilt host brings a fresh
                    // `remoteCommandCenter` with no targets.
                    self?.updateNowPlayingCommands()
                }
            }
            .store(in: &cancellables)
    }

    /// A session paused long enough in the background is torn down by
    /// AetherEngine's grace-window teardown, which releases the decode session
    /// to stay suspension-safe. It then reports `state == .paused` with
    /// `isSessionReady == false`, and `play()` forwards to the torn-down
    /// transport host and no-ops.
    ///
    /// Calling `reloadAtCurrentPosition()` on background return is the host's
    /// responsibility. Doing it here makes the repair invisible by the time the
    /// user is looking; `play()`'s own `desiredState: .play` call is the
    /// fallback for whatever races past. A still-live session is untouched.
    private func observeAppLifecycle() {
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverSessionIfNeeded(desiredState: .pause)
            }
        }
    }

    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>, isRemoteHLS: Bool) async throws {
        self.knownAtmosAudioTrackIndices = knownAtmosAudioTrackIndices
        // Order matters here beyond just readability: `LoadOptions`' own
        // memberwise init takes ~30 named, defaulted parameters, but Swift
        // still requires whichever ones a call site does supply to appear
        // in the init's own declared order, even with keyword syntax —
        // `isLive` before `nativeRemoteHLS` before `prepareNativeSubtitles`
        // before `externalSubtitles`.
        let options = LoadOptions(
            // A Jellyfin VOD transcode is not a live source, even when
            // consumed via the nativeRemoteHLS bypass below.
            isLive: false,
            // `true` only for a server-chosen HLS transcode
            // (`MediaSourceInfo.transcodingUrl`, "Allow Transcoding" mode)
            // — hands the playlist straight to AVPlayer instead of
            // AetherEngine's own FFmpeg demuxer/loopback path.
            nativeRemoteHLS: isRemoteHLS,
            // Gives `setNativeSubtitleRendering(_:)`, called on PiP entry and
            // exit below, a native WebVTT rendition to select.
            prepareNativeSubtitles: true,
            externalSubtitles: externalSubtitles.map(Self.makeExternalSubtitleTrack)
        )
        do {
            _ = try await engine.load(url: url, options: options)
        } catch is CancellationError {
            // A superseded `load()`/`stop()`, not a playback failure. Left
            // untouched so `PlayerViewModel`'s catch can filter it.
            throw CancellationError()
        } catch {
            // Such a failure also publishes a matching `.error` on
            // `$playbackPhase`; `suppressNextErrorPhase` skips that duplicate.
            suppressNextErrorPhase = true
            let fallbackMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw PlaybackLoadFailure(failure: PlaybackFailure(
                message: engine.errorInfo?.message ?? fallbackMessage,
                category: engine.errorInfo.map { Self.category(for: $0.kind) } ?? .transient
            ))
        }
        applyForcedSubtitleSelection()
    }

    /// Maps `PlaybackErrorKind` onto the recovery category `PlayerView` acts on.
    /// That type is a string-backed struct rather than an enum so a host's
    /// switch survives minor AetherEngine releases, which this mirrors with a
    /// `default:` sending unrecognized kinds to `.transient`. Non-`private` so
    /// tests can call it without a live engine.
    static func category(for kind: PlaybackErrorKind) -> PlaybackFailure.Category {
        switch kind {
        case .sourceRateLimited:
            // Origin metering (429/503/509), expected to recover. Retry.
            return .rateLimited
        case .sourceRefused, .dolbyVisionRequiresHardware, .hlsPlaylistOnRawLivePath, .demuxedAudioLiveUnsupported:
            // An access refusal, or content this device can never play.
            return .refused
        default:
            return .transient
        }
    }

    /// A forced subtitle track captions content the audio doesn't carry in the
    /// viewer's language — foreign dialogue, on-screen signs — so players
    /// activate one on load regardless of the general subtitles preference.
    /// Runs once after a fresh `load()`; a later `selectSubtitleTrack(id:)`
    /// pick is unaffected, since this call has already made the host's explicit
    /// choice.
    ///
    /// Keys off `TrackInfo.isForced`, the container's FORCED disposition, which
    /// covers embedded and declared-external tracks alike. No title matching.
    ///
    /// With more than one forced track — rare, but possible on a multi-language
    /// rip — prefers the one whose language matches the active audio track,
    /// keeping container order among ties, and falls back to the first forced
    /// track when none match or the audio language is unknown.
    private func applyForcedSubtitleSelection() {
        let forcedTracks = engine.subtitleTracks.filter(\.isForced)
        guard !forcedTracks.isEmpty else { return }
        let audioLanguage = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }?.language
        let best = forcedTracks.first { Self.languageMatches($0.language, audioLanguage) } ?? forcedTracks[0]
        selectSubtitleTrack(id: best.id)
    }

    /// Case-insensitive trimmed equality, simpler than AetherEngine's internal
    /// matcher — which folds ISO 639-1/639-2 B/T variants and English names
    /// together but isn't exposed outside the package. Sufficient here: both
    /// tracks come from the same container, which tags them with the same
    /// convention. `nil` on either side never matches.
    private static func languageMatches(_ trackLanguage: String?, _ other: String?) -> Bool {
        guard let trackLanguage = trackLanguage?.trimmingCharacters(in: .whitespaces), !trackLanguage.isEmpty,
              let other = other?.trimmingCharacters(in: .whitespaces), !other.isEmpty else { return false }
        return trackLanguage.caseInsensitiveCompare(other) == .orderedSame
    }

    /// Fallback for `observeAppLifecycle()`'s reload, catching a race that left
    /// it undone by the time the user taps Play, instead of a dead button.
    func play() {
        recoverSessionIfNeeded(desiredState: .play)
    }

    /// Shared by `observeAppLifecycle()`'s foreground-return repair and
    /// `play()`'s fallback, which both react to a paused session torn down by
    /// AetherEngine's background grace window.
    ///
    /// Applies `desiredState` immediately when the session is already ready.
    /// Otherwise it records what the single in-flight reload should apply, so a
    /// second caller overwrites the end state rather than starting a competing
    /// reload and the last caller's intent wins.
    ///
    /// `reloadAtCurrentPosition()` always resumes playback — its autostart comes
    /// from the original `load()`'s `LoadOptions.autoplay` and AetherEngine has
    /// no "reload but stay paused" entry point — so `desiredState` must be
    /// reapplied after every reload. Two reloads racing over one session's
    /// `play()`/`pause()` is what silently re-paused a session the user had
    /// just resumed.
    private func recoverSessionIfNeeded(desiredState: SessionRecoveryDesiredState) {
        guard engine.state == .paused, !engine.isSessionReady else {
            if desiredState == .play { engine.play() }
            return
        }
        sessionRecoveryDesiredState = desiredState
        guard sessionRecoveryTask == nil else { return }
        sessionRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.engine.reloadAtCurrentPosition()
            } catch {
                // Surfaced through the `onStateChange` path `PlayerViewModel`
                // uses for every other terminal failure; swallowing it would
                // reproduce the dead Play button with no diagnostic trail.
                self.onStateChange?(.failed(PlaybackFailure(
                    message: String(localized: "Playback couldn't resume after being paused in the background.")
                )))
                self.sessionRecoveryTask = nil
                return
            }
            switch self.sessionRecoveryDesiredState {
            case .play: self.engine.play()
            case .pause: self.engine.pause()
            }
            self.sessionRecoveryTask = nil
        }
    }
    func pause() { engine.pause() }
    func togglePlayPause() { engine.togglePlayPause() }
    func stop() { engine.stop() }

    /// Arms a watchdog after each seek, turning a stuck backward seek —
    /// AetherEngine's wedge, upstream issue #93, mitigated but still partially
    /// reproducible — into a visible error rather than a silent freeze with no
    /// spinner. `engine.seek(to:)` never throws and there is no dedicated
    /// failure state; the phase simply never leaves `.seeking`/`.rebuffering`,
    /// so detecting it is the host's responsibility.
    ///
    /// `seekWatchdogGeneration` stops a superseded seek's watchdog firing
    /// against a stale `time`: only the latest call's may act.
    func seek(to time: TimeInterval) async {
        seekWatchdogGeneration += 1
        let generation = seekWatchdogGeneration
        seekWatchdogTask?.cancel()
        await engine.seek(to: time)
        seekWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.seekWatchdogTimeout))
            guard !Task.isCancelled, let self, generation == self.seekWatchdogGeneration else { return }
            let phase = self.engine.playbackPhase
            let stillSeeking: Bool
            switch phase {
            case .seeking, .rebuffering: stillSeeking = true
            default: stillSeeking = false
            }
            guard stillSeeking, abs(self.engine.currentTime - time) < 1.0 else { return }
            Self.logger.error("Seek watchdog fired: stuck at \(self.engine.currentTime, privacy: .public)s targeting \(time, privacy: .public)s after \(Self.seekWatchdogTimeout, privacy: .public)s")
            self.onStateChange?(.failed(PlaybackFailure(
                message: String(localized: "Seeking is taking longer than expected — playback may be stuck."),
                category: .transient
            )))
        }
    }

    func selectAudioTrack(id: Int) {
        engine.selectAudioTrack(index: id)
        selectedAudioTrackID = id
        audioTracks = audioTracks.map { $0.selected($0.id == id) }
    }

    func selectSubtitleTrack(id: Int?) {
        selectedSubtitleTrackID = id
        if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
        subtitleTracks = subtitleTracks.map { $0.selected($0.id == id) }
    }

    func makeSurface() -> AnyView {
        AnyView(AetherPlayerSurface(engine: engine))
    }

    // MARK: - Picture in Picture

    func startPictureInPicture() { pipController?.startPictureInPicture() }
    func stopPictureInPicture() { pipController?.stopPictureInPicture() }

    /// Rebuilds `pipController` around the current `engine.nativePlayerLayer`,
    /// from the `engine.$currentAVPlayer` subscription. The old controller is
    /// dropped: AVKit tolerates one going out of scope mid-session, and a
    /// `playerLayer`-based controller has no swap-the-layer API.
    ///
    /// A same-host reload can re-emit `$currentAVPlayer` while a PiP window is
    /// up, so an outgoing mid-session controller needs
    /// `handlePictureInPictureDidStop()`'s cleanup mirrored first. AVKit never
    /// calls `didStopPictureInPicture` on a controller the host dropped, so
    /// nothing else would reset `engine.pictureInPictureActive`.
    private func updatePictureInPictureController() {
        if pipController?.isPictureInPictureActive == true {
            handlePictureInPictureDidStop()
        }
        pipPossibleObservation = nil
        pipController = nil
        onPictureInPicturePossibleChange?(false)

        guard let layer = engine.nativePlayerLayer, AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = pipDelegateProxy
        // Auto-starts PiP when the app backgrounds mid-playback, with no
        // scene-phase observing needed anywhere in the app.
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
        pipPossibleObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
            let possible = change.newValue ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onPictureInPicturePossibleChange?(possible)
                }
            }
        }
    }

    /// `engine.pictureInPictureActive` drives AetherEngine's background
    /// keepalive policy. This is the only place that sets it, kept in lockstep
    /// with AVKit rather than inferred.
    ///
    /// `setNativeSubtitleRendering(true)` hands the selected subtitle track to
    /// AVKit as a native WebVTT rendition, since the app's own
    /// `SubtitleOverlayView` isn't visible inside the captured layer.
    fileprivate func handlePictureInPictureDidStart() {
        engine.pictureInPictureActive = true
        engine.setNativeSubtitleRendering(true)
        onPictureInPictureActiveChange?(true)
    }

    /// Mirrors `handlePictureInPictureDidStart`, deselecting the native
    /// rendition so an in-app frame doesn't draw the app's overlay cues on top
    /// of AVKit's burned-in ones.
    fileprivate func handlePictureInPictureDidStop() {
        engine.pictureInPictureActive = false
        engine.setNativeSubtitleRendering(false)
        onPictureInPictureActiveChange?(false)
    }

    /// Logged only: PiP failing to start isn't fatal to in-app playback, the
    /// reset below is enough recovery, and the button self-disables via
    /// `onPictureInPicturePossibleChange`.
    fileprivate func handlePictureInPictureFailedToStart(_ error: Error) {
        Self.logger.error("Picture in Picture failed to start: \(error.localizedDescription, privacy: .public)")
        onPictureInPictureActiveChange?(false)
    }

    // MARK: - Now Playing

    func setNowPlayingInfo(title: String, subtitle: String?, artwork: UIImage?) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        info[MPMediaItemPropertyArtist] = subtitle
        if let artwork {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(artwork)
        }
        engine.setVideoNowPlayingInfo(info)
    }

    /// `nonisolated` to avoid a crash. MediaPlayer calls
    /// `MPMediaItemArtwork`'s request handler off-main, from its own
    /// Now-Playing serialization, to render the JPEG for Control Center. A
    /// closure literal written inside `setNowPlayingInfo` would infer
    /// `@MainActor` from that enclosing context — despite a declared type of
    /// plain `(CGSize) -> UIImage` — and Swift's runtime isolation check then
    /// traps on the first call. Defined in a `nonisolated` function, the
    /// closure has no isolation to inherit and runs on the caller's thread.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Registers play/pause/skip against `engine.videoNowPlayingSession`'s
    /// `remoteCommandCenter`, required once `ownsVideoNowPlayingSession` is set:
    /// owning the session makes the host responsible for wiring commands, and
    /// the session's auto-published elapsed/rate/duration covers info only.
    ///
    /// `removeTarget(nil)` before each `addTarget` stops handlers stacking if
    /// this runs again against a still-live command center, which a same-host
    /// reload can cause.
    ///
    /// The 15s/30s skip intervals match the in-app transport controls, so
    /// Control Center behaves the same as the app.
    private func updateNowPlayingCommands() {
        guard let center = engine.videoNowPlayingSession?.remoteCommandCenter else { return }

        center.playCommand.removeTarget(nil)
        center.playCommand.addTarget { [weak self] _ in
            self?.engine.play()
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.addTarget { [weak self] _ in
            self?.engine.pause()
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.engine.togglePlayPause()
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let target = max(0, engine.currentTime - 15)
            Task { await self.engine.seek(to: target) }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let target = min(engine.duration, engine.currentTime + 30)
            Task { await self.engine.seek(to: target) }
            return .success
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { await self.engine.seek(to: event.positionTime) }
            return .success
        }
    }

    // MARK: - Bridging

    private static func makeExternalSubtitleTrack(_ source: ExternalSubtitleSource) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(
            url: source.url,
            name: source.name,
            language: source.language,
            isForced: source.isForced,
            isHearingImpaired: source.isHearingImpaired,
            isDefault: source.isDefault,
            formatHint: source.formatHint
        )
    }

    private static func describe(_ format: VideoFormat) -> String? {
        switch format {
        case .sdr: return nil
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg: return "HLG"
        }
    }

    /// `describe(_:)`'s cases for `PlaybackStats` rather than the scrubber
    /// badge: always returns a label, including "SDR" where `describe(_:)`
    /// returns `nil`, and folds in the Dolby Vision profile number when known.
    private static func describeColorFormat(_ format: VideoFormat, dvProfile: Int?) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return dvProfile.map { "Dolby Vision (Profile \($0))" } ?? "Dolby Vision"
        case .hlg: return "HLG"
        }
    }

    private static func formatBitrate(_ bitsPerSecond: Int64) -> String {
        String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
    }

    /// `rawValue.capitalized` mangles the camelCase cases ("remoteBypass" →
    /// "Remotebypass"), so each is spelled out.
    private static func describeVideoRoute(_ route: VideoRoute) -> String {
        switch route {
        case .none: return "None"
        case .remoteBypass: return "Remote Bypass"
        case .loopback: return "Loopback"
        case .software: return "Software"
        case .audio: return "Audio"
        }
    }

    /// `stats.bufferedSeconds`' route-agnostic path. Reports how far ahead the
    /// far edge of the loaded range containing the playhead sits, falling back
    /// to the last range when none contains it exactly — a boundary can land on
    /// the playhead to floating-point precision.
    private static func bufferedAheadSeconds(item: AVPlayerItem, currentTime: Double) -> Double? {
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        let range = ranges.first { range in
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            return currentTime >= start && currentTime <= end
        } ?? ranges.last
        guard let range else { return nil }
        let end = (range.start + range.duration).seconds
        guard end.isFinite else { return nil }
        return max(0, end - currentTime)
    }

    /// The Stats-for-Nerds label for `TrackInfo.channels`, a plain count.
    /// `isAtmos` takes priority over the raw count, as AetherEngine recommends:
    /// surface "Atmos" rather than the bed channel count.
    private static func describeChannels(_ track: TrackInfo?) -> String? {
        guard let track, track.channels > 0 else { return nil }
        if track.isAtmos { return "Atmos" }
        switch track.channels {
        case 1: return "1.0"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(track.channels)ch"
        }
    }

    private static func normalize(
        _ tracks: [TrackInfo], kind: PlaybackTrack.Kind, selectedID: Int?,
        knownAtmosAudioTrackIndices: Set<Int> = []
    ) -> [PlaybackTrack] {
        tracks.map { track in
            // Threaded through both `title(for:)` and `metadataLabel(for:)`:
            // the latter needs to know whether the former will show the
            // provided name instead of the language, so it can put the
            // language back on the metadata line.
            let providedName = descriptiveName(track)
            return PlaybackTrack(
                id: track.id,
                kind: kind,
                title: title(for: track, providedName: providedName),
                metadata: metadataLabel(
                    for: track, kind: kind, providedName: providedName,
                    knownAtmosAudioTrackIndices: knownAtmosAudioTrackIndices
                ),
                isSelected: track.id == selectedID
            )
        }
    }

    /// The row's main line: `providedName` when `track.name` is a descriptive
    /// title ("Director's Commentary"), else a friendly name from
    /// `track.language`. Muxers commonly set `name` to a bare echo of the
    /// language ("ENG", "ENG (srt)"), which `descriptiveName(_:)` filters out so
    /// this falls through to the language name.
    private static func title(for track: TrackInfo, providedName: String?) -> String {
        if let providedName { return providedName }
        if let language = track.language, let friendly = friendlyLanguageName(language) { return friendly }
        if !track.name.isEmpty { return track.name }
        return String(localized: "Track \(track.id)")
    }

    /// `nil` when `track.name` is empty, or when — after stripping a trailing
    /// parenthetical like the "(srt)" in "ENG (srt)" — it is just the language
    /// code or its friendly name in different casing. Returned verbatim only
    /// for a name carrying information beyond the language.
    private static func descriptiveName(_ track: TrackInfo) -> String? {
        guard !track.name.isEmpty else { return nil }
        guard let language = track.language, !language.isEmpty else { return track.name }
        let stripped = track.name
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if stripped.caseInsensitiveCompare(language) == .orderedSame { return nil }
        if let friendly = friendlyLanguageName(language), stripped.caseInsensitiveCompare(friendly) == .orderedSame {
            return nil
        }
        return track.name
    }

    private static func friendlyLanguageName(_ languageCode: String) -> String? {
        Locale.current.localizedString(forIdentifier: languageCode)
    }

    /// The row's secondary line: the applicable flags in fixed order,
    /// dot-joined. `nil` when none apply, so `selectionRow` shows a single-line
    /// row rather than an empty second one.
    ///
    /// A non-nil `providedName` means `title(for:providedName:)` will show it
    /// instead of the language, which would then appear nowhere on the row, so
    /// the language leads the flag list — "English · Commentary" under
    /// "Director's Commentary".
    ///
    /// Audio tracks also get format, an "Atmos" flag, and channel layout after
    /// the language and ahead of the boolean flags. None apply to subtitles,
    /// hence the `kind` gate.
    ///
    /// "Atmos" is additive to `audioFormatLabel` rather than replacing it: a
    /// Dolby Digital Plus/Atmos track is a DD+ track first, the way the file's
    /// own title reads "Dolby Digital Plus Atmos". Its source is `track.isAtmos`
    /// or `knownAtmosAudioTrackIndices`, forwarded from Jellyfin's
    /// `MediaStream.audioSpatialFormat` at load.
    private static func metadataLabel(
        for track: TrackInfo, kind: PlaybackTrack.Kind, providedName: String?,
        knownAtmosAudioTrackIndices: Set<Int>
    ) -> String? {
        var flags: [String] = []
        if providedName != nil, let language = track.language, let friendly = friendlyLanguageName(language) {
            flags.append(friendly)
        }
        if kind == .audio {
            if let format = audioFormatLabel(for: track) { flags.append(format) }
            if track.isAtmos || knownAtmosAudioTrackIndices.contains(track.id) { flags.append("Atmos") }
            if let channels = channelsLabel(for: track) { flags.append(channels) }
        }
        if track.isDefault { flags.append(String(localized: "Default")) }
        if track.isForced { flags.append(String(localized: "Forced")) }
        if track.isHearingImpaired { flags.append(String(localized: "Hearing Impaired")) }
        if track.isCommentary { flags.append(String(localized: "Commentary")) }
        if track.isExternal { flags.append(String(localized: "External")) }
        return flags.isEmpty ? nil : flags.joined(separator: " \u{00B7} ")
    }

    /// The metadata line's audio-format entry: the codec family, in the same
    /// shorthand `MediaItem.metadataBadges` uses for the Details tab. Unlike
    /// that badge, which reads server-side `MediaStream.profile` and can tell
    /// DTS-HD from core DTS, `TrackInfo.codec` carries no profile, so every
    /// DTS-family track reads as plain "DTS". `nil` for a codec with no
    /// established shorthand, rather than a raw libavcodec name.
    ///
    /// Does not special-case `track.isAtmos`; `metadataLabel` appends "Atmos"
    /// separately. Returning "Dolby Atmos" in place of the codec would lose
    /// real information: DD+/Atmos and TrueHD/Atmos both carry Atmos but are
    /// not interchangeable, TrueHD's lossless core being the better carrier.
    ///
    /// `"dca"` matches DTS because `Demuxer.trackInfo(from:)` takes `codec`
    /// from the FFmpeg decoder's registered name rather than the codec's
    /// canonical short name, and FFmpeg registers its DTS decoder as `dca`.
    /// `"dts"` remains for the case where no decoder is built and the
    /// codec-descriptor name is used.
    private static func audioFormatLabel(for track: TrackInfo) -> String? {
        switch track.codec.lowercased() {
        case "ac3": return "DD"
        case "eac3": return "DD+"
        case "truehd": return "Dolby TrueHD"
        case "dts", "dca": return "DTS"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        default:
            return track.codec.hasPrefix("pcm") ? "PCM" : nil
        }
    }

    /// The metadata line's channel layout, in friendlier labels
    /// ("Mono"/"Stereo") than `describeChannels`' denser diagnostics readout
    /// ("1.0"/"2.0"). Does not collapse to "Atmos" the way that one does:
    /// `audioFormatLabel` surfaces it, and the bed channel count is still
    /// useful alongside.
    private static func channelsLabel(for track: TrackInfo) -> String? {
        guard track.channels > 0 else { return nil }
        switch track.channels {
        case 1: return String(localized: "Mono")
        case 2: return String(localized: "Stereo")
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(track.channels)ch"
        }
    }

    private static func normalize(_ cue: SubtitleCue) -> SubtitleCueDisplay {
        SubtitleCueDisplay(
            id: cue.id,
            startTime: cue.startTime,
            endTime: cue.endTime,
            body: normalize(cue.body),
            placement: cue.placement.map { SubtitleCueDisplay.Placement(alignment: $0.alignment, position: $0.position) }
        )
    }

    private static func normalize(_ body: SubtitleCue.Body) -> SubtitleCueDisplay.Body {
        switch body {
        case .text(let string):
            return .text(string)
        case .richText(let runs):
            return .richText(runs.map(normalize))
        case .image(let image):
            return .image(image.cgImage, rect: image.position, canvasSize: image.canvasSize)
        }
    }

    private static func normalize(_ run: SubtitleTextRun) -> SubtitleCueDisplay.Run {
        SubtitleCueDisplay.Run(
            text: run.text,
            color: run.color.map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) },
            isBold: run.isBold,
            isItalic: run.isItalic,
            isUnderlined: run.isUnderlined,
            isStruckThrough: run.isStruckThrough
        )
    }
}

// MARK: - AVPictureInPictureControllerDelegate

/// Pure forwarding to `AetherPlaybackEngine.handlePictureInPicture...`. See
/// `AetherPlaybackEngine.pipDelegateProxy` for why this is a separate object.
@MainActor
private final class PictureInPictureDelegateProxy: NSObject, @MainActor AVPictureInPictureControllerDelegate {
    weak var engine: AetherPlaybackEngine?

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        engine?.handlePictureInPictureDidStart()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        engine?.handlePictureInPictureDidStop()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
    ) {
        engine?.handlePictureInPictureFailedToStart(error)
    }

    /// `PlayerView` is never dismissed to start PiP — the button shows a
    /// placeholder over the still-presented player — so there is nothing to
    /// re-present.
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
