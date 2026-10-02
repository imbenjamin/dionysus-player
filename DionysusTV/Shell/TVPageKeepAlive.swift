import Foundation

/// Which pages of the shell's stack are built (Benjamin, 2026-10-01). Level 0
/// is the root page (Home, Search, a library, Profile); level `n` is the
/// path's `n`th entry. The root, the top and the two beneath the top stay
/// alive, so Menu returns to a page exactly as it was; anything deeper is
/// torn down and rebuilt from its kept view model on the way back.
///
/// The cost of a live page is memory (its decoded images), not frame time: a
/// hidden page isn't drawn. The cap bounds that at four pages.
enum TVPageKeepAlive {
    static let liveBeneathTop = 2

    static func liveLevels(depth: Int) -> Set<Int> {
        let top = max(0, depth)
        return Set([0] + Array(max(0, top - liveBeneathTop)...top))
    }
}
