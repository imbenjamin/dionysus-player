import Foundation
import Observation

/// Full-screen covers over the shell, bottom to top: today only the player.
/// Only the topmost page draws its content (Benjamin, 2026-10-01): the app is
/// image heavy, so while anything covers the shell, the shell (its page and
/// the sidebar) tears its views down, keeps only its view models and the
/// focused item, and rebuilds when it's uncovered. Pages within the shell
/// (each library, and M3's details page) don't push here: the shell builds
/// only the one on show.
///
/// A cover pushes when it opens and pops when it's really dismissed, from
/// whoever presents it. The player is presented with UIKit, outside SwiftUI,
/// so it's pushed by `TVPlayerPresenter` and popped by its host on dismissal.
@MainActor
@Observable
final class TVPageStack {
    static let shared = TVPageStack()

    struct Page: Hashable {
        fileprivate let id = UUID()
    }

    private var pages: [Page] = []

    var isShellCovered: Bool { !pages.isEmpty }

    /// How many pages cover the shell. The UI-test harness reads it through
    /// the player (`A11yID.TV.Player.coveringPages`), since XCUITest can't see
    /// beneath a UIKit modal to tell whether what's there was torn down.
    var depth: Int { pages.count }

    func push() -> Page {
        let page = Page()
        pages.append(page)
        return page
    }

    /// Removes `page` wherever it is: a cover's disappearance can arrive
    /// after the next page has already appeared.
    func pop(_ page: Page) {
        pages.removeAll { $0 == page }
    }

    /// Whether anything sits above `page`.
    func isCovered(_ page: Page) -> Bool {
        guard let index = pages.firstIndex(of: page) else { return false }
        return index < pages.count - 1
    }
}
