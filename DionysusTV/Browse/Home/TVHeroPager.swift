import Foundation

/// Which hero item is on show, and when the timer may move it.
///
/// The timer and Right on More Info both move forward and wrap to the first
/// item after the last (Benjamin, 2026-10-04). There is no paging back: Left
/// on Play always opens the rail. A press by hand stops the timer until
/// focus has left the hero and come back: someone paging through is reading.
struct TVHeroPager: Equatable {
    /// Long enough to read the overview (Benjamin, 2026-10-04); iOS's
    /// `HeroRailView` uses five.
    static let interval: Duration = .seconds(10)
    /// `interval` for an animation's duration: the pip fills over it.
    static var intervalSeconds: TimeInterval {
        Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
    }

    private(set) var index = 0
    private(set) var stoppedByHand = false
    private var count: Int

    init(count: Int) { self.count = max(0, count) }

    var canGoForward: Bool { count > 1 }

    mutating func tick() {
        guard count > 1 else { return }
        index = (index + 1) % count
    }

    mutating func forward() {
        stoppedByHand = true
        tick()
    }

    mutating func heroLostFocus() { stoppedByHand = false }

    mutating func setCount(_ newCount: Int) {
        count = max(0, newCount)
        index = min(index, max(0, count - 1))
    }

    static func timerRuns(
        count: Int, autoCarousel: Bool, reduceMotion: Bool, motionFrozen: Bool,
        heroHasFocus: Bool, isOnShow: Bool, stoppedByHand: Bool
    ) -> Bool {
        count > 1 && autoCarousel && !reduceMotion && !motionFrozen && heroHasFocus && isOnShow && !stoppedByHand
    }
}
