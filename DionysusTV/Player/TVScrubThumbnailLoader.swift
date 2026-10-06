import CoreGraphics
import Foundation
import Observation

/// The scrub preview's trickplay still, fetched at most every 0.12s while
/// the preview moves, the throttle iOS's scrubber uses
/// (`PlayerControlsOverlay.scrubThumbnailThrottleInterval`). A throttle, not
/// a debounce: a long scan would otherwise never fetch until it stopped.
@Observable
@MainActor
final class TVScrubThumbnailLoader {
    static let throttle: TimeInterval = 0.12

    private(set) var image: CGImage?
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private let fetch: @MainActor (Double) async -> CGImage?
    @ObservationIgnored private var lastFetchAt: TimeInterval = -.infinity
    @ObservationIgnored private var pending: Double?
    @ObservationIgnored private var trailing: Task<Void, Never>?

    init(
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        fetch: @escaping @MainActor (Double) async -> CGImage?
    ) {
        self.clock = clock
        self.fetch = fetch
    }

    func request(_ seconds: Double) {
        pending = seconds
        if clock() - lastFetchAt >= Self.throttle {
            fire()
        } else if trailing == nil {
            trailing = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.throttle))
                guard let self, !Task.isCancelled else { return }
                self.trailing = nil
                self.fire()
            }
        }
    }

    func reset() {
        trailing?.cancel()
        trailing = nil
        pending = nil
        image = nil
    }

    private func fire() {
        guard let seconds = pending else { return }
        pending = nil
        lastFetchAt = clock()
        Task { [weak self, fetch] in
            if let image = await fetch(seconds) { self?.image = image }
        }
    }
}
