import AVKit
import Combine
import Foundation
import MediaPlayer
import SwiftUI
import UIKit
import AetherEngine

/// `PlaybackEngine` implemented on top of AetherEngine.
///
/// Adapts AetherEngine's Combine publishers and its `TrackInfo` / `VideoFormat`
/// / `PlaybackState` shapes onto the app's own smaller `PlaybackEngine`
/// protocol so feature code (the player view model and controls overlay)
/// never touches AetherEngine's types directly.
@MainActor
final class AetherPlaybackEngine: PlaybackEngine {
    private let engine: AetherEngine
    private var cancellables: Set<AnyCancellable> = []
    /// See `observeAppLifecycle()`'s doc comment — repairs a paused session
    /// AetherEngine's own background grace-window teardown left without a
    /// pipeline to resume.
    private var didBecomeActiveObserver: NSObjectProtocol?
    /// Whichever end-state `recoverSessionIfNeeded(desiredState:)`'s single
    /// in-flight reload should apply once it resolves — see that method's
    /// own doc comment for the race this and `sessionRecoveryTask` together
    /// fix.
    private enum SessionRecoveryDesiredState { case play, pause }
    private var sessionRecoveryDesiredState: SessionRecoveryDesiredState = .pause
    private var sessionRecoveryTask: Task<Void, Never>?

    var onStateChange: ((PlaybackState) -> Void)?
    var onTimeUpdate: ((TimeInterval, TimeInterval) -> Void)?
    var onSubtitleCuesChange: (([SubtitleCueDisplay]) -> Void)?
    var onSourceTimeUpdate: ((TimeInterval) -> Void)?
    var onPictureInPicturePossibleChange: ((Bool) -> Void)?
    var onPictureInPictureActiveChange: ((Bool) -> Void)?

    /// Built around `engine.nativePlayerLayer` — the native (AVPlayer) route
    /// only, see `PlaybackEngine.onPictureInPicturePossibleChange`'s doc
    /// comment. (Re)built from the `engine.$currentAVPlayer` sink below,
    /// which is documented as "re-emitted on every reload" — exactly when a
    /// stale layer needs replacing with a fresh one, or a session that just
    /// went native for the first time gets one at all.
    private var pipController: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    /// `AVPictureInPictureControllerDelegate` is an Objective-C protocol
    /// (`NSObjectProtocol`-bound), which this plain Swift class can't
    /// conform to directly without giving up its own throwing, argument-less
    /// `init()` (NSObject's own non-throwing `init()` would occupy that same
    /// signature) — a tiny dedicated `NSObject` proxy sidesteps that instead
    /// of retrofitting inheritance onto this class for one protocol.
    private let pipDelegateProxy = PictureInPictureDelegateProxy()

    private(set) var audioTracks: [PlaybackTrack] = []
    private(set) var subtitleTracks: [PlaybackTrack] = []
    private(set) var videoFormatDescription: String?

    /// Read straight off `engine`'s own stored properties, same reasoning as
    /// `stats` above — they're set once per source and rarely re-read.
    var videoNaturalSize: CGSize? {
        guard engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 else { return nil }
        return CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight))
    }

    private var selectedAudioTrackID: Int?
    private var selectedSubtitleTrackID: Int?
    /// Set once per `load(url:externalSubtitles:knownAtmosAudioTrackIndices:)`
    /// call, read by the `$audioTracks` subscription below every time
    /// AetherEngine republishes the list — see that parameter's doc comment
    /// on the protocol for why this exists.
    private var knownAtmosAudioTrackIndices: Set<Int> = []

    /// Bridges to AetherEngine's own `videoGravity`, which drives whichever
    /// `AVPlayerLayer`/`AVSampleBufferDisplayLayer` is currently bound —
    /// `.resizeAspect` (letterboxed, nothing cropped) for `.fit`,
    /// `.resizeAspectFill` (fills the layer's bounds, cropping any excess)
    /// for `.fill`. Read back from `engine.videoGravity` rather than
    /// mirrored in a stored property, so this can't drift from what's
    /// actually applied to the render layer.
    var zoomMode: VideoZoomMode {
        get { engine.videoGravity == .resizeAspectFill ? .fill : .fit }
        set { engine.videoGravity = newValue == .fill ? .resizeAspectFill : .resizeAspect }
    }

    /// Reads straight off `engine`'s own published/stored properties on
    /// every access rather than mirroring them into stored state — this is
    /// only ever read a couple times a second by `PlaybackStatsOverlay`'s
    /// poll, so there's no reason to duplicate AetherEngine's own bookkeeping
    /// just to save a handful of property reads.
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
            // Native-only — see `PlaybackStats.bufferedSeconds`'s doc
            // comment. Confirmed live against a real server/title:
            // AetherEngine's own internal diagnostics (its 30 s memprobe
            // log) showed a software-decode session with every native-path
            // counter (`cacheCount`, `avioFetchedMB`, ...) sitting at a
            // flat 0 while `swFrames` climbed steadily — i.e. genuinely on
            // the software backend, where `bufferedPosition` tracks the
            // playhead by definition rather than any real read-ahead, so
            // diffing it (against either `currentTime` or `sourceTime` —
            // both were tried) can only ever read ~0.
            bufferedSeconds: engine.playbackBackend == .native
                ? max(0, engine.bufferedPosition - engine.sourceTime)
                : nil,
            // `liveTelemetry`'s 1 Hz sampler runs for every session despite
            // the "live" name (started unconditionally alongside the memory
            // probe, not gated on `isLive`) — `cachedBytes` on it is the
            // resident size of the exact same segment cache `bufferedSeconds`
            // above reads the read-ahead frontier from, so it's `nil` in
            // the same native-only case for the same reason.
            bufferedBytes: engine.liveTelemetry?.cachedBytes,
            currentTime: engine.currentTime,
            duration: engine.duration
        )
    }

    init() throws {
        self.engine = try AetherEngine()
        pipDelegateProxy.engine = self
        // Opts into owning the system Now-Playing session on the native
        // video path — off by default in AetherEngine because it's also
        // consumed by `AVPlayerViewController` hosts, where AVKit owns
        // Now-Playing itself. This app renders its own transport chrome
        // (`makeSurface()` + `PlayerControlsOverlay`, never AVKit's own
        // player UI), so it's exactly the "custom UI" case that's meant to
        // opt in. Must be set before `load()` — see `AetherEngine
        // .ownsVideoNowPlayingSession`'s doc comment.
        engine.ownsVideoNowPlayingSession = true
        observeEngine()
        observeAppLifecycle()
    }

    // `isolated deinit` — `didBecomeActiveObserver` is `@MainActor`-isolated
    // state (this whole class is `@MainActor`), which a plain `nonisolated
    // deinit` can't touch directly under Swift 6 strict concurrency.
    isolated deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    private func observeEngine() {
        // `$playbackPhase`, not the narrower `$state` this used to watch.
        // AetherEngine can report a mid-playback buffer underrun
        // (`.rebuffering`) or a dropped/retrying source connection
        // (`.stalled(reconnecting:)`) while `state` itself is still
        // `.playing` — see AetherEngine's own `PlaybackPhase.derive(...)` —
        // so `state` alone can't distinguish "actually playing" from
        // "frames stopped, working on it". That gap showed up concretely as
        // the buffering spinner never appearing when a scrub landed
        // somewhere that then needed to rebuffer: `state` stayed `.playing`
        // throughout, so `isBuffering` in `PlayerControlsOverlay` (which
        // only ever saw this bridged value) had nothing to key off.
        // `.rebuffering` and `.stalled` are bridged to *separate* app-level
        // states (`.buffering` vs. `.reconnecting`) rather than folded
        // together, so the UI can tell a healthy buffer underrun apart from
        // an actual dropped source connection — and so PlayerViewModel can
        // consult `ConnectivityMonitor` specifically when a `.reconnecting`
        // spell ends in `.failed`, not when an ordinary rebuffer does.
        engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
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
                case .error(let message): bridged = .failed(message)
                }
                MainActor.assumeIsolated {
                    self?.onStateChange?(bridged)
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

        // `engine.duration` is `@Published` on AetherEngine and settles from
        // its own dedicated sink inside AetherEngine's loading path,
        // independent of `clock.$currentTime`'s ticks above — a fresh
        // duration can land before, after, or well outside any clock tick
        // (there is no tick at all while paused, since nothing is advancing
        // to publish). Bridging `onTimeUpdate` only off `clock.$currentTime`
        // — the first version of this — meant a duration that settled after
        // the last tick a paused session would ever produce just never
        // reached `PlayerViewModel`. Confirmed live (2026-08-20,
        // screenshot): the background-teardown reload in
        // `reloadIfBackgroundTeardownLeftSessionUnready()` re-pauses right
        // after reloading, and its own reload can outlast the last real
        // tick — `PlayerViewModel.currentTime` (correct, from that last
        // tick) and `.duration` (stuck at 0) visibly disagreed, "19:09" next
        // to a scrubber pinned at the left edge and a "-0:00" remaining-time
        // label. A one-shot manual nudge right after that reload's `pause()`
        // was tried first and wasn't enough — `engine.duration` itself can
        // still read 0 at that exact instant if AetherEngine's own duration
        // sink hasn't landed yet. Mirroring `$duration`'s own publisher here
        // instead means whenever it actually lands, this fires — no guessing
        // about timing.
        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onTimeUpdate?(self.engine.currentTime, duration)
                }
            }
            .store(in: &cancellables)

        // Separate from `clock.$currentTime` above on purpose — subtitle
        // cues are stamped in source PTS, which can diverge from the item/
        // AVPlayer-axis clock across producer restarts (see
        // `PlaybackEngine.onSourceTimeUpdate`'s doc comment).
        engine.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sourceTime in
                MainActor.assumeIsolated {
                    self?.onSourceTimeUpdate?(sourceTime)
                }
            }
            .store(in: &cancellables)

        // AetherEngine draws nothing itself ("the engine emits SubtitleCue;
        // your UI paints them") — this is the only place cues cross into
        // the app, normalized to `SubtitleCueDisplay` so the rest of the
        // app never touches AetherEngine's `SubtitleCue`/`SubtitleTextRun`/
        // `SubtitleImage` directly, same as `audioTracks`/`subtitleTracks`
        // above do for `TrackInfo`.
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

        // `selectedAudioTrackID`/`selectedSubtitleTrackID` used to be written
        // *only* from `selectAudioTrack(id:)`/`selectSubtitleTrack(id:)` — an
        // explicit user pick — which left both `nil` (so nothing showed a
        // checkmark) for the entire stretch between load and the first
        // manual selection, even though AetherEngine had already resolved
        // and was actively playing a default track the whole time. These two
        // subscriptions pick up that resolved default (and any other
        // engine-internal change to the active track, e.g. after the
        // `reloadWithAudioOverride` a track switch triggers) directly from
        // AetherEngine's own published `activeAudioTrackIndex`/
        // `activeSubtitleTrackIndex`, independent of firing order against
        // the `$audioTracks`/`$subtitleTracks` subscriptions above — whichever
        // of the two arrives second is what actually paints the checkmark,
        // and either order lands on the same result.
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

        // Re-emitted on every reload (per its own doc comment) — exactly
        // when `engine.nativePlayerLayer` can go from nil to a fresh layer,
        // or from one layer to a newly-rebuilt one, so this is the signal to
        // (re)build the PiP controller around whatever layer exists now.
        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updatePictureInPictureController()
                    // Same signal, same reasoning: `engine.videoNowPlayingSession`
                    // only exists once a native host does, and a rebuilt host
                    // means a fresh `remoteCommandCenter` with no targets on
                    // it yet.
                    self?.updateNowPlayingCommands()
                }
            }
            .store(in: &cancellables)
    }

    /// Repairs a real bug, confirmed live (2026-08-20): pause a session
    /// (don't exit the player), lock the phone, wait past AetherEngine's
    /// own `backgroundTeardownGraceSeconds` (15s default — a couple of
    /// minutes locked is nowhere close) — its `#127` grace-window teardown
    /// releases the decode session to stay suspension-safe (see
    /// `AetherEngine`'s own doc comments on `teardownVideoForBackground`/
    /// `reloadAtCurrentPosition`), leaving `state == .paused` but
    /// `isSessionReady == false`: a session with nothing left to resume.
    /// AetherEngine's own `play()` just forwards to the (now torn-down)
    /// transport host and silently no-ops — tapping Play does nothing,
    /// the exact symptom reported; only backing out and restarting playback
    /// recovered. `reloadAtCurrentPosition()`'s own doc comment says
    /// "Call after background return" — that call is this host's
    /// responsibility, not something AetherEngine does for itself
    /// (confirmed: its own `didBecomeActive` observer only cancels the
    /// grace window, never reloads). Reloading proactively here, right on
    /// foreground return, means the fix is invisible by the time the user
    /// is actually looking at the screen — `play()`'s own `desiredState:
    /// .play` call is a defensive fallback for whatever races past this.
    /// A session that's still alive (a quick app switch inside the grace
    /// window, or one AetherEngine itself kept playing through the
    /// background) is untouched: `isSessionReady` only goes false for a
    /// session AetherEngine actually tore down. See
    /// `recoverSessionIfNeeded(desiredState:)`'s own doc comment for the
    /// rest of this repair's history — three more real bugs, found live in
    /// quick succession right after this one.
    private func observeAppLifecycle() {
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverSessionIfNeeded(desiredState: .pause)
            }
        }
    }

    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>) async throws {
        self.knownAtmosAudioTrackIndices = knownAtmosAudioTrackIndices
        let options = LoadOptions(
            // Needed for `setNativeSubtitleRendering(_:)` (called on PiP
            // entry/exit below) to have a native WebVTT rendition to select
            // at all — see that method's doc comment in AetherEngine.
            prepareNativeSubtitles: true,
            externalSubtitles: externalSubtitles.map(Self.makeExternalSubtitleTrack)
        )
        _ = try await engine.load(url: url, options: options)
        applyForcedSubtitleSelection()
    }

    /// A "forced" subtitle track exists specifically to caption content the audio track doesn't
    /// already carry in the viewer's language (foreign-language dialogue, on-screen signs) — real
    /// players activate one on load regardless of the viewer's general subtitles-on/off preference,
    /// rather than waiting for an explicit pick. Runs once, right after a fresh `load()`; a later
    /// user pick (`selectSubtitleTrack(id:)`) is untouched by this — there's nothing left for it to
    /// do once the host (this call) has already made an explicit choice, same as any other
    /// `hostExplicitSubtitleAction`.
    ///
    /// Source is `TrackInfo.isForced` — the container's own FORCED disposition — covering embedded
    /// *and* declared-external tracks alike (both are seated in `engine.subtitleTracks` by the time
    /// `engine.load()` returns; see `registerDeclaredExternalSubtitles`'s doc comment). No title/name
    /// text-matching, same principle as `knownAtmosAudioTrackIndices` above.
    ///
    /// Selection when more than one forced track exists (rare — most sources carry at most one, but
    /// nothing stops a multi-language disc/rip from carrying several): prefer whichever forced
    /// track's language matches the audio track AetherEngine resolved as active for this load,
    /// keeping the first match in container order if more than one still ties; fall back to the
    /// first forced track in container order if none match (or the active audio track's language is
    /// unknown). Confirmed live (2026-08-14) against a real "Captain Phillips" source carrying an
    /// English Forced track alongside full subtitle tracks.
    private func applyForcedSubtitleSelection() {
        let forcedTracks = engine.subtitleTracks.filter(\.isForced)
        guard !forcedTracks.isEmpty else { return }
        let audioLanguage = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }?.language
        let best = forcedTracks.first { Self.languageMatches($0.language, audioLanguage) } ?? forcedTracks[0]
        selectSubtitleTrack(id: best.id)
    }

    /// Case-insensitive, trimmed equality — deliberately simpler than AetherEngine's own internal
    /// language matcher (which also folds ISO 639-1/639-2 B/T variants and English names together,
    /// e.g. "en"/"eng"/"english"), since that helper isn't exposed outside the package. A non-issue
    /// in practice: the forced subtitle track and the audio track it's compared against come from the
    /// same container, which tags both with the same language-code convention (almost always plain
    /// ISO 639-2), so an exact match after trimming/casing is enough. `nil` on either side never
    /// matches, same as AetherEngine's own rule.
    private static func languageMatches(_ trackLanguage: String?, _ other: String?) -> Bool {
        guard let trackLanguage = trackLanguage?.trimmingCharacters(in: .whitespaces), !trackLanguage.isEmpty,
              let other = other?.trimmingCharacters(in: .whitespaces), !other.isEmpty else { return false }
        return trackLanguage.caseInsensitiveCompare(other) == .orderedSame
    }

    /// Defensive fallback for `observeAppLifecycle()`'s proactive reload —
    /// see that method's doc comment for the underlying bug (a paused
    /// session torn down by AetherEngine's own background grace-window
    /// teardown reports `state == .paused` but `isSessionReady == false`,
    /// and AetherEngine's own `play()` has no pipeline left to act on).
    /// Whatever race left that reload undone by the time the user actually
    /// taps Play, this catches it here instead of a silently-dead button —
    /// same "kick off the async step, then act" shape AetherEngine's own
    /// `play()` already uses for its "rewind a VOD parked at its final
    /// frame" case.
    func play() {
        recoverSessionIfNeeded(desiredState: .play)
    }

    /// Shared by `observeAppLifecycle()`'s proactive foreground-return
    /// repair (`desiredState: .pause`) and `play()`'s own defensive
    /// fallback (`desiredState: .play`) — both react to the identical
    /// "paused session torn down by AetherEngine's background grace
    /// window" condition `observeAppLifecycle()`'s own doc comment
    /// describes. When the guard is already satisfied (the common case —
    /// nothing to repair), applies `desiredState` immediately and
    /// synchronously. Otherwise, records `desiredState` as the one this
    /// single in-flight reload should apply once it resolves — a second
    /// caller arriving mid-reload doesn't start a competing reload of its
    /// own, it just overwrites which end-state wins, so the *last*
    /// caller's intent always applies regardless of which caller happened
    /// to start the reload in the first place.
    ///
    /// Three more real bugs, found live in quick succession right after
    /// the original fix shipped (all 2026-08-20):
    /// - `reloadAtCurrentPosition()` takes no parameters of its own — its
    ///   autostart behavior is entirely inherited from `LoadOptions
    ///   .autoplay` as captured at the *original* `load()` call, which
    ///   `load(url:externalSubtitles:knownAtmosAudioTrackIndices:)` never
    ///   overrides (`LoadOptions.autoplay` defaults to `true`). So a
    ///   reload always resumes playback, even for `desiredState: .pause`
    ///   — the case a genuinely-paused session hits every time. AetherEngine
    ///   has no "reload but stay paused" entry point to ask for instead,
    ///   so `desiredState` is applied explicitly right after the reload
    ///   settles — same net effect (paused, pipeline alive, `isSessionReady`
    ///   true, a later `play()` works) with at most a brief internal
    ///   autostart the user was never looking at (`.pause`'s own caller,
    ///   `observeAppLifecycle()`, runs on `didBecomeActive`, before the
    ///   screen is realistically in view) rather than a
    ///   perceptibly-sustained unwanted resume.
    /// - Re-pausing right after the reload could land on the last
    ///   `PlayerViewModel.currentTime`/`.duration` update this session
    ///   would ever get while paused (nothing advancing = nothing left to
    ///   tick), with `duration` not yet caught up — "19:09" next to a
    ///   "-0:00" remaining-time label and a scrubber pinned at the left
    ///   edge (screenshot confirmed). Fixed at the source, not here — see
    ///   `observeEngine()`'s `engine.$duration` subscription, which now
    ///   bridges independently of `clock.$currentTime`'s ticks, so
    ///   whenever the real duration lands (paused or not) `onTimeUpdate`
    ///   fires regardless.
    /// - This method and `play()` used to each fire their own independent,
    ///   untracked `Task { try? await engine.reloadAtCurrentPosition();
    ///   engine.<x>() }` against the exact same guard condition — if a
    ///   foreground-triggered reload was still in flight when the user
    ///   tapped Play, `play()`'s own guard was still true (nothing had
    ///   flipped `isSessionReady` yet), so it started a *second*,
    ///   redundant reload; whichever task's trailing `.pause()`/`.play()`
    ///   call landed last won the race, and since the foreground-triggered
    ///   task runs first in practice (`didBecomeActive` fires before the
    ///   user can realistically tap anything), its own `.pause()` could
    ///   land *after* the user's `play()` task had already resolved —
    ///   silently overwriting the user's own tap and reproducing, via a
    ///   race between this fix's own two entry points, the exact "tap
    ///   Play, nothing happens" symptom the original fix exists to solve.
    ///   `sessionRecoveryDesiredState`/`sessionRecoveryTask` above are what
    ///   fix this — a single shared in-flight reload, with the *last*
    ///   caller's `desiredState` always winning once it resolves.
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
                // A real gap found alongside the race above: this used to
                // be `try?`-swallowed with zero diagnostic trail — if the
                // reload itself throws, proceeding to call `.play()`/
                // `.pause()` on a session with (per this method's own doc
                // comment) "no pipeline left to act on" would silently
                // reproduce the original dead-Play-button bug, just with
                // no way to tell why. Surfaced through the same
                // `onStateChange` path `PlayerViewModel` already listens
                // to for every other terminal engine failure, rather than
                // introducing a second, bespoke error-reporting channel.
                self.onStateChange?(.failed(String(localized: "Playback couldn't resume after being paused in the background.")))
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

    func seek(to time: TimeInterval) async {
        await engine.seek(to: time)
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

    /// (Re)builds `pipController` around whatever `engine.nativePlayerLayer`
    /// currently is — called from the `engine.$currentAVPlayer` subscription
    /// in `observeEngine()`, see that call site's comment for why that's the
    /// right signal. The old controller (if any) is just dropped: AVKit
    /// tolerates a controller going out of scope mid-session, and there's no
    /// "swap the layer" API for a `playerLayer`-based controller the way
    /// there is for a sample-buffer `ContentSource`.
    ///
    /// If the outgoing controller was mid-PiP-session (a same-host reload —
    /// e.g. a stall/reconnect folded into `.buffering` — can re-emit
    /// `$currentAVPlayer` while a PiP window is still up), dropping it
    /// without first mirroring `handlePictureInPictureDidStop()`'s cleanup
    /// would leave `engine.pictureInPictureActive`/`onPictureInPictureActiveChange`
    /// stuck at `true` forever: AVKit never calls the old delegate's
    /// `didStopPictureInPicture` for a controller that simply went out of
    /// scope on the host's side, so nothing else would ever reset it.
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
        // The one flag that makes backgrounding while this session is
        // playing auto-start PiP, with no app-level scene-phase observing
        // needed anywhere in the app.
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

    /// `engine.pictureInPictureActive` drives AetherEngine's own background
    /// keepalive policy (see that property's doc comment) — this is the one
    /// place in the app that ever sets it, kept in lockstep with AVKit's own
    /// notion of "a PiP window is showing" rather than inferred from
    /// anything else. `setNativeSubtitleRendering(true)` hands whichever
    /// subtitle track is currently selected to AVKit as a native WebVTT
    /// rendition, since the app's own `SubtitleOverlayView` isn't visible
    /// inside the captured layer.
    fileprivate func handlePictureInPictureDidStart() {
        engine.pictureInPictureActive = true
        engine.setNativeSubtitleRendering(true)
        onPictureInPictureActiveChange?(true)
    }

    /// Mirrors `handlePictureInPictureDidStart` — deselects the native
    /// rendition so a subsequent in-app frame doesn't double-draw the app's
    /// own overlay cues on top of AVKit's burned-in ones.
    fileprivate func handlePictureInPictureDidStop() {
        engine.pictureInPictureActive = false
        engine.setNativeSubtitleRendering(false)
        onPictureInPictureActiveChange?(false)
    }

    fileprivate func handlePictureInPictureFailedToStart() {
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

    /// `nonisolated`, not just factored out — the crash this fixed (device,
    /// 2026-08-16): `MPMediaItemArtwork`'s request handler is called back
    /// later, off-main, by MediaPlayer's own Now-Playing serialization
    /// (`-[MPMediaItemArtwork jpegDataWithSize:]` on a background dispatch
    /// queue) to actually render the JPEG for Control Center/the lock
    /// screen. A closure literal written directly in `setNowPlayingInfo`
    /// (a `@MainActor` method, since the whole class is) infers `@MainActor`
    /// isolation from that enclosing context even though its declared type —
    /// a plain synchronous `(CGSize) -> UIImage`, nothing async or
    /// `@MainActor` in `MPMediaItemArtwork`'s own signature — never asked
    /// for that; Swift's runtime isolation check then traps the instant
    /// MediaPlayer calls it from anywhere but the main actor, which is
    /// unconditionally what it does. Defining the closure inside a
    /// `nonisolated` function instead means it has no enclosing isolation to
    /// inherit, so it can run on whatever thread the caller uses, which is
    /// exactly what this handler needs to tolerate.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Registers play/pause/skip against `engine.videoNowPlayingSession`'s
    /// own `remoteCommandCenter` — required once `ownsVideoNowPlayingSession`
    /// is on (set in `init`): AetherEngine's own doc comment is explicit that
    /// owning the session means the host, not the system, is responsible for
    /// wiring commands, and the session auto-publishing elapsed/rate/duration
    /// only covers *info*, not *handling* taps.
    ///
    /// `removeTarget(nil)` before every `addTarget` guards against stacking
    /// duplicate handlers if this runs again against the same still-live
    /// `remoteCommandCenter` (a same-host reload also re-emits
    /// `$currentAVPlayer` — see the call site) — harmless on a freshly built
    /// one, where there's nothing to remove yet.
    ///
    /// Skip intervals (15s back / 30s forward) match the in-app transport
    /// controls' own `gobackward.15`/`goforward.30` buttons, so Control
    /// Center/the lock screen behaves the same as the app itself.
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

    /// Same cases as `describe(_:)` above, but for `PlaybackStats` rather
    /// than the scrubber's format badge: always returns a label (including
    /// "SDR", where `describe(_:)` returns `nil` so the badge just doesn't
    /// show), and folds in the Dolby Vision profile number when known.
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

    /// `TrackInfo.channels` is a plain count (2/6/8/...) meant, per its own
    /// doc comment, "for Stats-for-Nerds" — this is that label. `isAtmos`
    /// takes priority over the raw count, same as AetherEngine's own doc
    /// comment on that field recommends ("surface 'Atmos' instead of the
    /// bed channel count, typically 5.1").
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
            // Computed once and threaded through both `title(for:)` and
            // `metadataLabel(for:)` — the latter needs to know whether the
            // former is *about* to show the provided name rather than the
            // language, so it can put the language back on the metadata
            // line instead of losing it entirely (see that doc comment).
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

    /// The row's main line: `providedName` (`track.name`, when it reads as
    /// a genuinely descriptive title, e.g. "Director's Commentary") when
    /// there is one, otherwise a user-friendly language name built from
    /// `track.language`. Muxers commonly set `name` to a bare, none-too-
    /// friendly echo of the language field ("ENG", "ENG (srt)") that adds
    /// no information beyond what `metadataLabel(for:)` and the language
    /// itself already cover — `descriptiveName(_:)` filters those out so
    /// this falls through to the friendly language name instead of showing
    /// the raw label verbatim.
    private static func title(for track: TrackInfo, providedName: String?) -> String {
        if let providedName { return providedName }
        if let language = track.language, let friendly = friendlyLanguageName(language) { return friendly }
        if !track.name.isEmpty { return track.name }
        return String(localized: "Track \(track.id)")
    }

    /// `nil` when `track.name` is empty, or — once a trailing "(...)"
    /// parenthetical is stripped (the "(srt)" in "ENG (srt)") — is just the
    /// raw language code or its own friendly name wearing different
    /// capitalization ("ENG"/"eng"/"English" for an `.language` of "eng").
    /// Non-nil (and returned verbatim) only for a name that's actually
    /// carrying information beyond the language, like "Director's
    /// Commentary" or "Director's Commentary with Brad Pitt, Edward Norton
    /// & Helena Bonham Carter".
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

    /// The row's secondary line: whichever flags apply, in this fixed
    /// order, space-dot-joined — `nil` when none do, so `selectionRow`
    /// shows a single-line row rather than an empty second line.
    ///
    /// When `providedName` is non-nil, `title(for:providedName:)` is about
    /// to show it instead of the language — the language would otherwise
    /// not appear anywhere on the row at all, so it leads the flag list
    /// here instead (e.g. "English · Commentary" under "Director's
    /// Commentary").
    ///
    /// Audio tracks additionally get the format (e.g. "DD+"), an "Atmos"
    /// flag when applicable, and channel layout (e.g. "5.1") right after
    /// the language, ahead of the boolean flags — see
    /// `audioFormatLabel`/`channelsLabel`. None of the three apply to
    /// subtitle tracks (`channels`/codec-as-audio-format are meaningless
    /// there), hence `kind` gating them.
    ///
    /// "Atmos" is deliberately its own flag, additive to `audioFormatLabel`
    /// rather than replacing it (that was the original, wrong shape here —
    /// see that function's doc comment): a Dolby Digital Plus/Atmos track
    /// is still a DD+ track first and foremost, same as the file's own
    /// embedded title reads "Dolby TrueHD Atmos"/"Dolby Digital Plus
    /// Atmos" — format *and* Atmos together, never just one. Its source is
    /// `track.isAtmos` OR `knownAtmosAudioTrackIndices` (Jellyfin's own
    /// `MediaStream.audioSpatialFormat`, forwarded at load time) — see the
    /// `PlaybackEngine.load(url:externalSubtitles:knownAtmosAudioTrackIndices:)`
    /// doc comment for why both are needed rather than just the former.
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

    /// The metadata line's audio-format entry — the underlying codec
    /// family, same shorthand `MediaItem.metadataBadges` uses for the
    /// Details tab ("DD"/"DD+"/"Dolby TrueHD"/"DTS"), kept consistent
    /// across the app rather than inventing a second vocabulary here.
    /// Unlike that badge (server-side `MediaStream.profile`, which can
    /// tell DTS-HD apart from core DTS), `TrackInfo.codec` is just the bare
    /// libavcodec name with no profile info, so every DTS-family track
    /// reads as plain "DTS" here — an accepted simplification, not a bug,
    /// for this data source. `nil` for a codec with no established
    /// shorthand (rare in practice) rather than showing a raw, none-too-
    /// friendly libavcodec name verbatim.
    ///
    /// Deliberately does NOT special-case `track.isAtmos` — `metadataLabel`
    /// appends "Atmos" as its own separate flag instead. A first version of
    /// this returned "Dolby Atmos" here in place of the codec's own format
    /// (e.g. hiding "DD+"), which silently lost real information: a Dolby
    /// Digital Plus/Atmos track and a Dolby TrueHD/Atmos track both
    /// legitimately carry Atmos, but they're not interchangeable — TrueHD's
    /// lossless core is the higher-quality carrier of the two — and
    /// collapsing both to a bare "Dolby Atmos" made them indistinguishable
    /// (found live, 2026-08-14, on a Saving Private Ryan source with both).
    ///
    /// `"dca"` (not just `"dts"`) matches DTS: `Demuxer.trackInfo(from:)`
    /// sets `codec` from `avcodec_find_decoder(...).pointee.name` — the
    /// FFmpeg *decoder's* own registered name, not the codec's canonical
    /// short name — and FFmpeg's DTS decoder has historically been
    /// registered as `"dca"` (`ffmpeg -codecs` shows `dts ... (decoders:
    /// dca) (encoders: dca)`); confirmed live (2026-08-14) that every DTS
    /// track's `codec` actually reads `"dca"`, not `"dts"`. `"dts"` stays
    /// as a fallback for the rarer case `trackInfo(from:)` falls back to
    /// the codec-descriptor name (no decoder built).
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

    /// The metadata line's channel-layout entry — friendlier labels
    /// ("Mono"/"Stereo") than `describeChannels` above uses for Stats-for-
    /// Nerds ("1.0"/"2.0"), which is a denser diagnostics readout rather
    /// than a picker row a user reads at a glance. Deliberately does NOT
    /// collapse to "Atmos" for an Atmos track the way `describeChannels`
    /// does — `audioFormatLabel` already surfaces that, and the bed channel
    /// count (typically 5.1) is still useful alongside it here.
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

/// See `AetherPlaybackEngine.pipDelegateProxy`'s doc comment for why this is
/// a separate object rather than a delegate conformance on that class
/// directly. Pure forwarding — all the actual behavior lives on
/// `AetherPlaybackEngine.handlePictureInPicture...` methods.
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
        engine?.handlePictureInPictureFailedToStart()
    }

    /// `PlayerView` is never dismissed to start PiP (the manual button just
    /// shows a placeholder over the still-presented player), so there's
    /// nothing to re-present here — complete immediately.
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
