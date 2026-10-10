import SwiftUI

/// Home's hero (prototype screen 5): the current item's logo, a metadata
/// line, two lines of overview, Play and More Info, and page dots. Its
/// backdrop is the page's background, drawn by `TVHomeView` behind the rail.
///
/// Paging by hand uses an invisible focus guard right of More Info: when it
/// takes focus it turns the page, wrapping after the last item, and hands
/// focus back. There is none left of Play, so Left there opens the rail
/// (Benjamin, 2026-10-04).
struct TVHeroView: View {
    let item: MediaItem
    let count: Int
    @Binding var pager: TVHeroPager
    /// The timer is running: the current pip fills over its interval.
    let isCounting: Bool
    let focus: FocusState<String?>.Binding
    let play: () -> Void
    let moreInfo: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    static let playFocus = "hero.play"
    static let infoFocus = "hero.info"
    static let guardPrefix = "hero.guard."
    private static let forwardGuard = guardPrefix + "forward"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TVDetailHeader(item: item, showsBadges: false, titleIdentifier: A11yID.TV.Main.heroTitle)
            // Reserved at two lines, so the buttons don't move as the pages
            // turn between items with longer and shorter overviews.
            Text(verbatim: item.overview ?? " ")
                .lineLimit(2, reservesSpace: true)
                .frame(width: 900, alignment: .leading)
                .foregroundStyle(.white.opacity(0.82))
                .accessibilityHidden(!item.hasDescription)
            HStack(spacing: 22) {
                Button(action: play) { Label("Play", systemImage: "play.fill") }
                    .focused(focus, equals: Self.playFocus)
                    .accessibilityIdentifier(A11yID.TV.Main.heroPlay)
                    .modifier(nextItemAction)
                Button(action: moreInfo) { Label("More Info", systemImage: "info.circle") }
                    .focused(focus, equals: Self.infoFocus)
                    .accessibilityIdentifier(A11yID.TV.Main.heroInfo)
                    .modifier(nextItemAction)
                pageGuard(Self.forwardGuard, enabled: pager.canGoForward) {
                    withAnimation(.easeInOut(duration: 0.35)) { pager.forward() }
                    focus.wrappedValue = Self.infoFocus
                }
                Spacer()
                dots
            }
            .padding(.top, 16)
            .padding(.trailing, 140)
            // The whole width, so Up from a tile anywhere along the first rail
            // reaches the buttons (as on a detail page).
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
    }

    /// VoiceOver can't reach the paging guard, so both buttons page instead.
    private var nextItemAction: TVHeroNextItemAction {
        TVHeroNextItemAction(pager: $pager)
    }

    /// One point wide and unseen: it exists to catch a Left or Right that
    /// would otherwise leave the hero. Not focusable under VoiceOver, which
    /// would land on it and speak nothing; the row's Next Item action pages
    /// there instead.
    private func pageGuard(_ id: String, enabled: Bool, turn: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: 1, height: 60)
            .focusable(enabled && !voiceOverEnabled)
            .focused(focus, equals: id)
            .onChange(of: focus.wrappedValue) { _, now in
                if now == id { turn() }
            }
            .accessibilityHidden(true)
    }

    private var dots: some View {
        TVHeroDots(count: count, index: pager.index, isCounting: isCounting)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Item \(pager.index + 1) of \(count)"))
            .accessibilityIdentifier(A11yID.TV.Main.heroDots)
    }
}

/// The hero's "Next Item" action, on each of its buttons (M5).
private struct TVHeroNextItemAction: ViewModifier {
    @Binding var pager: TVHeroPager

    func body(content: Content) -> some View {
        content.accessibilityAction(named: Text("Next Item")) {
            guard pager.canGoForward else { return }
            withAnimation(.easeInOut(duration: 0.35)) { pager.forward() }
        }
    }
}

/// The page dots. While the timer runs, the current one is a bar that fills
/// over the interval, as iOS's does (`HeroPageIndicator`, Benjamin,
/// 2026-10-04); stopped, it's solid white. Each start counts a full
/// interval, as the timer does.
///
/// The fill is scaled, not resized, and is a new view at every start
/// (`generation`), so an animation in flight is never retargeted: the shape
/// iOS settled on.
private struct TVHeroDots: View {
    let count: Int
    let index: Int
    let isCounting: Bool
    @State private var fill: CGFloat = 0
    @State private var generation = 0

    private static let size: CGFloat = 12
    private static let currentWidth: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { dot in
                let isCurrent = dot == index
                Capsule()
                    .fill(.white.opacity(isCurrent && !isCounting ? 1 : 0.4))
                    .frame(width: isCurrent ? Self.currentWidth : Self.size, height: Self.size)
                    .overlay(alignment: .leading) {
                        if isCurrent, isCounting {
                            Capsule()
                                .fill(Color.dionysusHighlight)
                                .frame(width: Self.currentWidth, height: Self.size)
                                .scaleEffect(x: fill, y: 1, anchor: .leading)
                                .id(generation)
                        }
                    }
            }
        }
        .task(id: "\(isCounting)-\(index)") {
            generation += 1
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { fill = 0 }
            guard isCounting else { return }
            // A pass later, so the new fill exists at zero before it moves.
            await Task.yield()
            withAnimation(.linear(duration: TVHeroPager.intervalSeconds)) { fill = 1 }
        }
    }
}
