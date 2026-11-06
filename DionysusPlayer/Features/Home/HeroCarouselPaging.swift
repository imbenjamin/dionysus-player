import Foundation

/// The hero carousel's page arithmetic and auto-advance countdown, apart
/// from `HeroRailView` so they can be unit-tested (`HeroCarouselPagingTests`).
/// No journey sees the carousel move: the UI-test harness holds it still.
///
/// Positions index `HeroRailView.loopedItems`: the real items padded with a
/// copy of the last in front and of the first behind, so a swipe off either
/// end lands on a page showing the right item, then snaps (unanimated) into
/// the real range. One item or none is not padded.
struct HeroCarouselPaging: Equatable {
    /// How many real items the carousel shows.
    let count: Int

    /// Seconds an item stays before the carousel moves on.
    static let autoAdvanceInterval = 5

    /// Whether the carousel moves at all: with one item or none, nothing
    /// pages, loops or advances.
    var pages: Bool { count > 1 }

    /// How many pages the looped list has.
    var loopedCount: Int { pages ? count + 2 : count }

    /// The position of the first real item: past the leading copy.
    var firstPagePosition: Int { pages ? 1 : 0 }

    /// The real item a position shows, for the dot indicator; `0` before the
    /// first layout pass (`position == nil`).
    func index(atPosition position: Int?) -> Int {
        guard pages, let position else { return 0 }
        return (position - 1 + count) % count
    }

    /// One second of the countdown. Paused (a finger down, Home not on
    /// show, or the carousel set to manual), it holds where it was rather
    /// than restarting; at `autoAdvanceInterval` it starts again from zero
    /// and the carousel advances.
    func tick(idleSeconds: Int, isPaused: Bool) -> (idleSeconds: Int, advances: Bool) {
        guard pages, !isPaused else { return (idleSeconds, false) }
        let counted = idleSeconds + 1
        guard counted >= Self.autoAdvanceInterval else { return (counted, false) }
        return (0, true)
    }

    /// Where moving `delta` pages from `position` lands; `nil` when the
    /// carousel doesn't page. A position on a padding copy (a rapid second
    /// Previous/Next tap can land before the snap) is first read as the real
    /// page it copies, so the result never walks off the looped list.
    func position(from position: Int?, movingBy delta: Int) -> Int? {
        guard pages else { return nil }
        var current = position ?? firstPagePosition
        if current == 0 {
            current = count
        } else if current == loopedCount - 1 {
            current = 1
        }
        return current + delta
    }

    /// The real page a padding copy snaps back to once its slide ends; `nil`
    /// for a real page.
    func snapTarget(from position: Int) -> Int? {
        guard pages else { return nil }
        if position == 0 { return count }
        if position == loopedCount - 1 { return 1 }
        return nil
    }
}
