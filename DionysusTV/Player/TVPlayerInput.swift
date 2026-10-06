import Foundation
import Observation

/// Runs `TVPlayerInputModel` for the host: a clock, a 10 Hz tick while the
/// player is up, and the state the overlay draws from.
@Observable
@MainActor
final class TVPlayerInput {
    private(set) var state = TVPlayerInputState()
    @ObservationIgnored var context: () -> TVPlayerContext = { TVPlayerContext() }
    @ObservationIgnored var perform: ([TVPlayerCommand]) -> Void = { _ in }
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var ticker: Task<Void, Never>?

    static let tickInterval: Duration = .milliseconds(100)

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    func send(_ input: TVRemoteInput) {
        var next = state
        let commands = TVPlayerInputModel.reduce(&next, input, context: context(), now: clock())
        // Assigned only on change: every tick would otherwise invalidate the
        // overlay ten times a second.
        if next != state { state = next }
        if !commands.isEmpty { perform(commands) }
    }

    var swipeScrubs: Bool { TVPlayerInputModel.swipeScrubs(state, context: context()) }

    func start() {
        guard ticker == nil else { return }
        state.lastInputAt = clock()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                self?.send(.tick)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// A new item in the same player: everything starts over but Stats,
    /// which stays as the person left it (Review Focus 4).
    func reset() {
        state = TVPlayerInputState(lastInputAt: clock(), isStatsOn: state.isStatsOn)
    }
}
