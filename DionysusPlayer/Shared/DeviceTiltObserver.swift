// CoreMotion predates Swift's Sendable audit; `CMMotionManager` isn't
// marked Sendable despite Apple's own docs guaranteeing its instance
// methods are thread-safe ("enabling you to call them from any thread of
// your app"). `@preconcurrency` here (rather than scattering
// `nonisolated(unsafe)` at every capture site) is the standard bridge for
// exactly this situation — see `DeviceTiltObserver.motionManager`'s doc
// comment for the fuller reasoning.
@preconcurrency import CoreMotion
import Observation

/// Publishes smoothed, roughly `-1...1` device-tilt values for driving the
/// Details page hero's 3D depth effect (`HeroHeaderView` via
/// `BackdropLogoOverlay`), centered on the phone's natural *held-upright*
/// pose — top pointing at the sky, screen facing the user — rather than on
/// lying flat on a table.
///
/// `.shared` — a single instance for the whole app, rather than one per
/// `HeroHeaderView` — for two reasons: there's only one physical sensor
/// regardless of how many detail pages happen to be alive in various tabs'
/// nav stacks at once, and it gives `ProfileView`'s "3D Depth Effects"
/// toggle a single place to read `isApplyingChange` from (see that
/// property's doc comment) so it can show its own feedback independently of
/// whichever `HeroHeaderView` instance, if any, actually triggered the
/// change.
///
/// Deliberately reads `CMDeviceMotion.gravity` (the accelerometer's gravity
/// vector, in the device's own reference frame) rather than the raw
/// gyroscope's rotation rate — gravity gives an absolute "which way is the
/// device tilted right now" reading with no drift, so it can drive an
/// offset directly. Raw gyro rates are a *rate of change*, not a position;
/// using them for this would need continuous integration and periodic
/// re-centering to stay usable, for no benefit here.
///
/// Raw `gravity.x`/`gravity.y` aren't used as-is, though: `gravity.y` reads
/// `0` when the device is lying flat (screen facing up) and `-1` when it's
/// held perfectly upright — i.e. raw gravity treats *flat* as the neutral
/// position, and a normal in-hand holding angle as already near one extreme
/// of the range. That's backwards for a phone people hold roughly upright
/// while looking at it (confirmed against a real device: the raw mapping
/// read as needing the phone laid flat to center the effect at all).
/// `uprightRelativeY(_:)` below remaps `gravity.y` so *upright* reads `0`
/// instead, leaving `gravity.x` alone — the left/right axis already reads
/// `0` at rest regardless of how upright vs. reclined the phone is held,
/// since rolling it left/right is orthogonal to that axis.
@Observable
@MainActor
final class DeviceTiltObserver {
    static let shared = DeviceTiltObserver()

    private(set) var x: Double = 0
    private(set) var y: Double = 0

    /// True while `start()`/`stop()`'s underlying `CMMotionManager` call is
    /// actually in flight. CoreMotion's start/stop methods are documented
    /// as thread-safe ("enabling you to call them from any thread of your
    /// app") but can synchronously block for a couple of seconds on real
    /// hardware while negotiating with the motion coprocessor. Confirmed
    /// directly on a real device across two attempts: dispatching *our*
    /// call onto `motionQueue` below wasn't actually sufficient on its own
    /// — the app still froze whole. The real dependency was
    /// `updateDeliveryQueue` below being `.main`: `stopDeviceMotionUpdates()`
    /// has to synchronize with delivery to tear its handler down safely,
    /// so as long as delivery was `.main`, stopping from *any* thread still
    /// meant blocking the main run loop. With delivery moved off `.main`
    /// too, the app stays interactive throughout — but the operation still
    /// isn't instant, so this flag exists purely to give a caller
    /// (`ProfileView`'s toggle row, which now drives `start()`/`stop()`
    /// directly rather than relying on some `HeroHeaderView` happening to
    /// be mounted) something to show a spinner against, so the user isn't
    /// left wondering whether their tap landed.
    private(set) var isApplyingChange = false

    /// CMMotionManager's instance methods are documented as thread-safe, a
    /// guarantee `nonisolated(unsafe)` exists specifically to encode: this
    /// is a deliberate, informed override of Swift 6's Sendable checking
    /// (backed by Apple's own documented contract for this exact type), not
    /// a shortcut around a real data race. It's what lets `start()`/`stop()`
    /// below dispatch the actual CoreMotion call to `Self.motionQueue`
    /// instead of the main actor.
    private nonisolated(unsafe) let motionManager = CMMotionManager()

    private static let motionQueue = DispatchQueue(
        label: "com.imbenjamin.dionysusplayer.device-tilt", qos: .userInitiated
    )

    /// Where `startDeviceMotionUpdates(to:)` below delivers each sample —
    /// deliberately *not* `.main`. Confirmed the hard way: dispatching our
    /// own `stopDeviceMotionUpdates()` call onto `motionQueue` (above)
    /// wasn't enough to stop the app-wide freeze on toggle, because the
    /// freeze wasn't caused by which thread *we* called stop from —
    /// `stopDeviceMotionUpdates()` has to synchronize with whatever queue
    /// updates are being *delivered* to in order to safely tear the handler
    /// down, and that synchronization is what was blocking the main run
    /// loop when delivery was `.main`. Delivering here instead removes that
    /// dependency on the main queue entirely; the handler below hops back
    /// to the main actor itself, per-sample, only for the couple of
    /// property writes that actually need it.
    private nonisolated static let updateDeliveryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.imbenjamin.dionysusplayer.device-tilt.updates"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// `false` in the Simulator (no physical sensor) and on the rare device
    /// without one — callers should treat that as "the effect just doesn't
    /// animate," not an error; `start()` already no-ops safely either way.
    var isAvailable: Bool { motionManager.isDeviceMotionAvailable }

    /// How many `HeroHeaderView` instances currently want the sensor
    /// running — see `acquire()`/`release()`, below, for why `HeroHeaderView`
    /// goes through those instead of calling `start()`/`stop()` directly.
    private var activeObserverCount = 0
    /// Bumped on every `acquire()`/`release()`; a delayed `stop()` inside
    /// `release()` compares its own snapshot of this against the current
    /// value before actually stopping — see `release()`'s doc comment.
    private var generation = 0
    /// How long `release()` waits, once the count reaches zero, before it
    /// actually stops the sensor — long enough to cover the gap between one
    /// detail page's `.onDisappear` and the next one's `.onAppear` when
    /// navigating from one straight to another (confirmed live: comfortably
    /// covers it with room to spare), short enough that genuinely leaving
    /// the feature still stops the sensor promptly rather than lingering.
    private static let releaseGracePeriod: Duration = .milliseconds(500)

    /// Marks one more caller (a mounted `HeroHeaderView`) as wanting the
    /// sensor running, and starts it if it isn't already. Paired with
    /// exactly one `release()` call once that caller no longer needs it —
    /// see `HeroHeaderView`'s own `isObservingTilt` for how it keeps its
    /// acquire/release calls balanced across `.onAppear`/`.onDisappear`/its
    /// "3D Depth Effects" `.onChange`.
    ///
    /// This reference-counted pair — not `HeroHeaderView` calling
    /// `start()`/`stop()` directly from `.onAppear`/`.onDisappear` — is what
    /// actually fixes two problems at once. First, the race `start()`'s own
    /// doc comment used to describe as a reason to avoid `.onDisappear`
    /// entirely: pushing a new detail page fires the outgoing page's
    /// `.onDisappear` and the incoming page's `.onAppear` within moments of
    /// each other, and a naive stop-then-start there could leave the sensor
    /// dead if `stop()` landed after `start()` saw "already active" and
    /// no-opped. `release()`'s grace period below means the count never
    /// actually reaches a *sustained* zero across that gap, so no `stop()`
    /// fires at all. Second — the actual bug this pair was added to fix —
    /// once a detail page's `HeroHeaderView` had ever run at all, nothing
    /// short of the Profile toggle or Reduce Motion ever stopped the
    /// sensor again, even after backing out of the feature entirely: it
    /// kept sampling at 30 Hz for the rest of the app session. Real
    /// `.onDisappear`-driven `release()` calls, now safe to add because of
    /// the grace period above, are what let the sensor actually stop again
    /// once nothing's left that wants it.
    func acquire() async {
        activeObserverCount += 1
        generation += 1
        await start()
    }

    /// See `acquire()`. Only actually stops the sensor once the count has
    /// been at zero continuously for `releaseGracePeriod` — `generation`
    /// (bumped by every `acquire()`/`release()`) is what "continuously"
    /// checks: if another call comes in while this is waiting, the snapshot
    /// taken before the sleep no longer matches, and this bows out without
    /// stopping anything, leaving whichever later call is actually current
    /// in charge.
    func release() async {
        activeObserverCount = max(0, activeObserverCount - 1)
        generation += 1
        let generationAtRelease = generation
        guard activeObserverCount == 0 else { return }
        try? await Task.sleep(for: Self.releaseGracePeriod)
        guard activeObserverCount == 0, generation == generationAtRelease else { return }
        await stop()
    }

    /// Idempotent — safe to call from `.onAppear` even if already running
    /// (e.g. a rapid navigate-away-and-back). `async` so callers can `await`
    /// it (or just fire-and-forget via `Task { await ... }`) — see this
    /// type's doc comment for why the underlying work needs to be off the
    /// main actor at all. Prefer `acquire()`/`release()` over calling this
    /// directly from a view's lifecycle — see `acquire()`'s doc comment for
    /// why. `ProfileView`'s toggle and `warmUp()` below call this (and
    /// `stop()`) directly instead, deliberately: neither represents "a
    /// `HeroHeaderView` wants the sensor," so they've no count to keep
    /// balanced — both already idempotent against whatever `acquire()`/
    /// `release()` are independently doing.
    func start() async {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        isApplyingChange = true
        defer { isApplyingChange = false }
        let manager = motionManager
        await withCheckedContinuation { continuation in
            Self.motionQueue.async {
                // 30 Hz is plenty smooth for a slow, gentle drift effect and
                // is lighter than the default (and typically 60-100
                // Hz-capable) rate.
                manager.deviceMotionUpdateInterval = 1.0 / 30.0
                manager.startDeviceMotionUpdates(to: Self.updateDeliveryQueue) { [weak self] motion, _ in
                    guard let self, let motion else { return }
                    // Runs on `updateDeliveryQueue`, not the main actor —
                    // see that property's doc comment for why delivery was
                    // moved off `.main`. Pull the two raw values out here
                    // (plain `Double`s, trivially safe to cross actors)
                    // rather than hopping with the whole `CMDeviceMotion`.
                    let gravityX = motion.gravity.x
                    let gravityY = motion.gravity.y
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.x = Self.smoothed(current: self.x, sample: gravityX)
                        self.y = Self.smoothed(current: self.y, sample: Self.uprightRelativeY(gravityY))
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Pays CoreMotion's one-time daemon-connection bootstrap cost up
    /// front, at app launch, instead of whenever the user happens to first
    /// reach the "3D Depth Effects" toggle or a detail page. Confirmed on a
    /// real device: even with `start()`/`stop()`'s own work already off the
    /// main actor (see `updateDeliveryQueue`'s doc comment), the *very
    /// first* start/stop pair in a process's lifetime still visibly
    /// hitches for up to ~1s — every pair after that is immediate. That
    /// first hitch is CoreMotion itself standing up its connection to the
    /// motion daemon, not something under this type's control to make
    /// asynchronous; the fix is just to not let the user's first toggle
    /// tap be the moment that happens. Call once, early — `AppState.start()`
    /// fires this off (unawaited) during the splash/session-restore
    /// window, a loading moment where a brief hitch is already expected
    /// and invisible, rather than mid-interaction.
    func warmUp() async {
        await start()
        await stop()
    }

    /// See `start()` — same reasoning for being `async`/off-main.
    func stop() async {
        guard motionManager.isDeviceMotionActive else { return }
        isApplyingChange = true
        defer { isApplyingChange = false }
        let manager = motionManager
        await withCheckedContinuation { continuation in
            Self.motionQueue.async {
                manager.stopDeviceMotionUpdates()
                continuation.resume()
            }
        }
    }

    /// A simple exponential low-pass filter: each sample nudges the running
    /// value partway toward the latest reading rather than jumping straight
    /// to it, turning natural hand jitter into a smooth drift instead of a
    /// twitchy 30-times-a-second jump. Pulled out of the `CMMotionManager`
    /// callback above as its own pure function purely so it's unit-testable
    /// at all — nothing about the actual sensor I/O is.
    static func smoothed(current: Double, sample: Double, factor: Double = 0.15) -> Double {
        current + (sample - current) * factor
    }

    /// Shifts raw `gravity.y` (`-1` held upright, `0` lying flat — see this
    /// type's doc comment) so held-upright reads `0` instead: exactly
    /// `gravityY + 1`. Clamped to `-1...1` afterward — a phone reclined
    /// well past flat, or held upside down, would otherwise push past that
    /// range and produce a bigger offset than `BackdropLogoOverlay`'s
    /// depth-effect ranges were tuned for.
    static func uprightRelativeY(_ gravityY: Double) -> Double {
        max(-1, min(1, gravityY + 1))
    }
}
