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
    /// hardware while negotiating with the motion coprocessor — confirmed
    /// directly: before `motionQueue` below existed, turning "3D Depth
    /// Effects" off in Settings froze the *entire app* for a couple of
    /// seconds (not just this screen), because `stop()` ran that blocking
    /// call right on the main thread/actor. Now that the actual CoreMotion
    /// call happens on a background queue instead, the app stays
    /// interactive throughout — but the operation still isn't instant, so
    /// this flag exists purely to give a caller (`ProfileView`'s toggle
    /// row) something to show a spinner against, so the user isn't left
    /// wondering whether their tap landed.
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

    /// `false` in the Simulator (no physical sensor) and on the rare device
    /// without one — callers should treat that as "the effect just doesn't
    /// animate," not an error; `start()` already no-ops safely either way.
    var isAvailable: Bool { motionManager.isDeviceMotionAvailable }

    /// Idempotent — safe to call from `.onAppear` even if already running
    /// (e.g. a rapid navigate-away-and-back). `async` so callers can `await`
    /// it (or just fire-and-forget via `Task { await ... }`) — see this
    /// type's doc comment for why the underlying work needs to be off the
    /// main actor at all.
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
                manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                    guard let self, let motion else { return }
                    // The `to: .main` above guarantees this closure itself
                    // runs on the main thread/actor — `assumeIsolated` just
                    // tells the type system what's already true at runtime,
                    // rather than hopping through a fresh `Task` on every
                    // single sample (this fires up to 30 times/sec).
                    MainActor.assumeIsolated {
                        self.x = Self.smoothed(current: self.x, sample: motion.gravity.x)
                        self.y = Self.smoothed(current: self.y, sample: Self.uprightRelativeY(motion.gravity.y))
                    }
                }
                continuation.resume()
            }
        }
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
