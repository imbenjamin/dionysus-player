import Foundation
import Observation

/// Runs one delayed action, replacing any still waiting. Injected so tests
/// fire the settle themselves instead of sleeping.
@MainActor
protocol AudioOffsetScheduling: AnyObject {
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class TaskAudioOffsetScheduler: AudioOffsetScheduling {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// The player's audio offset for one title: the value in effect, the Audio
/// panel's scope, Reset, and when a change reaches the engine
/// (spec section 3). Both players' Audio panels draw from it.
///
/// A step saves at once and shows at once, but reaches the engine only after
/// `settleDelay` without another: on AetherEngine's native route each change
/// is a session-preserving reload (about 0.3 s of held picture), so applying
/// every 10 ms press would stutter.
@MainActor
@Observable
final class AudioOffsetController {
    static let settleDelay: Duration = .milliseconds(750)

    private(set) var milliseconds: Int
    private(set) var scope: AudioOffsetScope = .thisTitle
    /// From the engine's route; false hides every control.
    var isAvailable = false
    private(set) var hasTitleOffset: Bool

    var canDecrease: Bool { milliseconds > AudioOffset.range.lowerBound }
    var canIncrease: Bool { milliseconds < AudioOffset.range.upperBound }
    /// What `PlaybackEngine.load(...)` is given, so the first frame is in sync.
    var loadSeconds: TimeInterval { AudioOffset.seconds(milliseconds) }

    private let itemID: String
    private let store: AudioOffsetStore
    private let scheduler: AudioOffsetScheduling
    private let apply: @MainActor (Int) -> Void
    /// The value the engine has, so an unchanged value isn't re-applied.
    private var appliedMilliseconds: Int
    private var hasPending = false

    init(
        itemID: String, store: AudioOffsetStore,
        scheduler: AudioOffsetScheduling = TaskAudioOffsetScheduler(),
        apply: @escaping @MainActor (Int) -> Void
    ) {
        self.itemID = itemID
        self.store = store
        self.scheduler = scheduler
        self.apply = apply
        let own = store.offset(forItem: itemID)
        let initial = own ?? store.globalOffsetMilliseconds
        hasTitleOffset = own != nil
        milliseconds = initial
        appliedMilliseconds = initial
    }

    func step(by steps: Int) {
        let next = AudioOffset.normalized(milliseconds + steps * AudioOffset.step)
        guard next != milliseconds else { return }
        switch scope {
        case .thisTitle:
            store.setOffset(next, forItem: itemID)
            hasTitleOffset = true
        case .allTitles:
            store.globalOffsetMilliseconds = next
        }
        milliseconds = next
        scheduleApply()
    }

    func setScope(_ newScope: AudioOffsetScope) {
        guard newScope != scope else { return }
        scope = newScope
        guard newScope == .allTitles, hasTitleOffset else { return }
        followGlobal()
    }

    func resetToGlobal() {
        guard hasTitleOffset else { return }
        followGlobal()
    }

    func panelDidOpen() {
        scope = .thisTitle
    }

    /// Applies a waiting change now: the panel closed.
    func flush() {
        guard hasPending else { return }
        scheduler.cancel()
        applyNow()
    }

    /// Drops a waiting engine call; the value is already saved.
    func cancelPending() {
        scheduler.cancel()
        hasPending = false
    }

    private func followGlobal() {
        store.removeOffset(forItem: itemID)
        hasTitleOffset = false
        let global = store.globalOffsetMilliseconds
        guard global != milliseconds else { return }
        milliseconds = global
        scheduleApply()
    }

    private func scheduleApply() {
        hasPending = true
        scheduler.schedule(after: Self.settleDelay) { [weak self] in self?.applyNow() }
    }

    private func applyNow() {
        hasPending = false
        guard isAvailable, milliseconds != appliedMilliseconds else { return }
        appliedMilliseconds = milliseconds
        apply(milliseconds)
    }
}
