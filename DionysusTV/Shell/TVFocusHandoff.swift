import SwiftUI

extension EnvironmentValues {
    /// Bumped by the shell each time it hands focus from the sidebar to the
    /// page on show, after asking the focus system to look again. A page with
    /// a SwiftUI focus target (Profile's Switch User, a first tile) sets it
    /// again on each change: claiming it only on appear raced the shell's
    /// request, which under load could land elsewhere.
    @Entry var tvFocusHandoff = 0

    /// Bumped when Right takes focus out of the open sidebar back into the
    /// page, without choosing a row. The page puts focus back on the item it
    /// last had: tvOS by itself picks whatever sits nearest the row, and on
    /// Home that's the hero's Play, level with Home's row, however far down
    /// the rails focus had been.
    @Entry var tvRailReturn = 0

    /// Whether the sidebar is open, which is whenever one of its rows has
    /// focus. `TVPageScaffold` pushes the content right while it is, and a
    /// page doesn't pull focus out of it when its items arrive.
    @Entry var tvSidebarExpanded = false

    /// Called by the page on show once it has put focus on one of its items,
    /// so the shell can let the rail take focus again: it holds the rail
    /// disabled until then, or tvOS's first focus pass would land on the
    /// rail (leftmost) and open it.
    @Entry var tvPageClaimedFocus: @MainActor () -> Void = {}

    /// Called by the page on show as it starts putting focus on an item, so
    /// the shell holds the rail until the claim lands (`tvPageClaimedFocus`).
    /// A page claims more than once: its loading spinner, then its first item
    /// when the data arrives. On tvOS 26 the spinner's removal makes tvOS
    /// pick a new focus itself, before the claim lands, and with the rail
    /// free it picked the rail and opened it (measured on tvOS 26.5; tvOS 27
    /// honours the claim).
    @Entry var tvPageClaimingFocus: @MainActor () -> Void = {}
}
