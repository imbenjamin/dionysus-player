import SwiftUI
import UIKit

/// The signed-in shell (prototype screens 5, 6 and 6b): one top-level page
/// (Profile, Home, Search or a library) with the custom `TVSidebar` beside it,
/// collapsed to a rail of icons on every page (Benjamin, 2026-10-01).
///
/// Left from a page's leftmost item, or Menu on a page, opens the sidebar on
/// that page's row; Menu with it open is left to tvOS, which leaves the app.
/// Choosing a row opens its page, collapses the sidebar and puts focus on the
/// page's first item. Where the shell is, and which rows can take focus, is
/// `TVShellNavigation`.
///
/// Only the page on show is built (the app is image heavy): choosing another
/// tears the old one down. The shell keeps each page's data and the item that
/// last had focus, so a rebuilt page comes back as it was. The player is the
/// exception: it's laid over the page, which stays as it is beneath.
struct TVMainView: View {
    @Environment(AppState.self) private var appState
    let client: JellyfinAPIClient
    let userID: String

    @State private var sidebar: TVSidebarModel
    @State private var home: HomeViewModel
    @State private var search: SearchViewModel
    @State private var libraryGrids: [String: CollectionGridViewModel] = [:]
    @State private var rememberedHomeTile: String?
    @State private var rememberedSearchResult: String?
    @State private var rememberedLibraryItems: [String: String] = [:]
    /// One view model per pushed page, keyed by its path entry, kept while
    /// the entry is on the path: a page torn down by the keep-alive cap
    /// rebuilds from it without a refetch.
    @State private var detailModels: [UUID: AssetDetailViewModel] = [:]
    @State private var pushedGrids: [UUID: CollectionGridViewModel] = [:]
    @State private var rememberedPushedFocus: [UUID: String] = [:]
    @State private var nav = TVShellNavigation()
    /// Holds the whole sidebar disabled while focus is on its way to the page,
    /// until the page says it has claimed it (`tvPageClaimedFocus`): on a
    /// fresh shell tvOS's first focus pass would otherwise land on the rail,
    /// the leftmost thing on screen, and open it; after a choice, a row that
    /// can still take focus keeps it.
    @State private var railHeld = true
    @State private var holdGeneration = 0
    /// See `EnvironmentValues.tvFocusHandoff`.
    @State private var focusHandoff = 0
    @FocusState private var focusedRow: TVSidebarLayout.Row?

    init(client: JellyfinAPIClient, userID: String) {
        self.client = client
        self.userID = userID
        _sidebar = State(initialValue: TVSidebarModel(client: client, userID: userID))
        _home = State(initialValue: HomeViewModel(client: client, userID: userID))
        _search = State(initialValue: SearchViewModel(client: client, userID: userID))
    }

    private var isExpanded: Bool { focusedRow != nil }
    private var libraries: [MediaItem] { sidebar.libraries }

    private var profileUser: UserDto? {
        TVProfileIdentity.user(currentUser: appState.currentUser, credentials: appState.sessionStore.credentials)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Beneath every page, so switching pages never shows the
            // window's plain black while the new one fades in.
            TVPageBackground()
                .ignoresSafeArea()

            pages

            Color(red: 8 / 255, green: 1 / 255, blue: 6 / 255)
                .opacity(isExpanded ? TVShellMetrics.dimOpacity : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            TVSidebar(
                rows: TVSidebarLayout.rows(libraries: libraries, librariesExpanded: nav.librariesExpanded),
                libraries: libraries,
                profileUser: profileUser,
                serverName: appState.sessionStore.serverConfiguration?.name,
                serverURL: appState.sessionStore.serverConfiguration?.baseURL,
                highlighted: Set(TVSidebarLayout.rows(libraries: libraries, librariesExpanded: true)
                    .filter { nav.isHighlighted($0, isExpanded: isExpanded, libraries: libraries) }),
                focusable: nav.focusableRows(isExpanded: isExpanded, libraries: libraries),
                isExpanded: isExpanded,
                librariesExpanded: nav.librariesExpanded,
                focus: $focusedRow,
                onSelect: select
            )
            .disabled(railHeld)
            .ignoresSafeArea()
        }
        .environment(\.tvSidebarExpanded, isExpanded)
        .environment(\.tvFocusHandoff, focusHandoff)
        .environment(\.tvPageClaimedFocus, releaseRail)
        .environment(\.tvOpenRoute, open)
        .environment(\.tvSelectLibrary) { id in select(.library(id)) }
        .animation(.easeOut(duration: 0.18), value: isExpanded)
        .animation(.easeOut(duration: 0.2), value: nav.librariesExpanded)
        .onExitCommand(perform: exitCommand)
        // Collapsed, focus can only enter on the anchor row; a folded
        // library's anchor is the Libraries row, so it moves on to the
        // library's own row once that's drawn.
        .onChange(of: focusedRow) { old, new in
            guard old == nil, let new else { return }
            let target = nav.enterRail(libraries: libraries)
            guard new != target else { return }
            // The library's row is drawn and enabled only once the panel has
            // opened, which can take more than one pass, so try a few times.
            Task { @MainActor in
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard focusedRow != nil, focusedRow != target else { return }
                    focusedRow = target
                }
            }
        }
        .onAppear { holdRail() }
        .task { await sidebar.loadIfNeeded() }
        // A load that failed at launch (offline, or a server still starting)
        // is tried again whenever the rail is used, not only at next launch.
        .onChange(of: focusedRow) { _, row in
            guard row != nil, sidebar.loadState == .failed else { return }
            Task { await sidebar.loadIfNeeded() }
        }
    }

    /// The root page and the pushed pages the cap keeps alive
    /// (`TVPageKeepAlive`). Only the top one is on show; the rest are built
    /// but hidden and disabled, so Menu returns to them as they were.
    private var pages: some View {
        let live = TVPageKeepAlive.liveLevels(depth: nav.path.count)
        return ZStack {
            level(0) { page }
                .id(nav.destination)
                // Removed at once: a page fading out could still take focus.
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            ForEach(Array(nav.path.enumerated()), id: \.element.id) { index, entry in
                if live.contains(index + 1) {
                    level(index + 1) { pushedPage(entry) }
                }
            }
        }
    }

    private func level<Page: View>(_ level: Int, @ViewBuilder _ page: () -> Page) -> some View {
        let onShow = level == nav.path.count
        return page()
            .environment(\.tvPageIsOnShow, onShow)
            .opacity(onShow ? 1 : 0)
            .disabled(!onShow)
            .accessibilityHidden(!onShow)
    }

    @ViewBuilder
    private func pushedPage(_ entry: TVPathEntry) -> some View {
        let focus = Binding(
            get: { rememberedPushedFocus[entry.id] },
            set: { rememberedPushedFocus[entry.id] = $0 }
        )
        switch entry.route {
        case .assetDetail:
            if let model = detailModels[entry.id] {
                TVDetailPage(viewModel: model, client: client, userID: userID, rememberedFocus: focus)
            }
        case .collection(let query):
            if let grid = pushedGrids[entry.id] {
                TVCollectionGridView(title: query.title, titleIdentifier: A11yID.TV.Library.title(query.title), viewModel: grid, rememberedItemID: focus)
            }
        default:
            // The downloaded routes don't exist on tvOS.
            EmptyView()
        }
    }

    private func open(_ route: AppRoute) {
        let entry = nav.push(route)
        switch route {
        case .assetDetail(let itemID, let preloadedItem):
            detailModels[entry.id] = AssetDetailViewModel(client: client, userID: userID, itemID: itemID, preloadedItem: preloadedItem)
        case .collection(let query):
            pushedGrids[entry.id] = CollectionGridViewModel(client: client, userID: userID, query: query)
        default:
            break
        }
        // The tile that was focused is now disabled; without the hold, tvOS
        // moves focus to the rail, the only thing left, and opens it.
        holdRail()
    }

    private func pop() {
        guard let entry = nav.pop() else { return }
        detailModels[entry.id]?.cancelBackgroundWork()
        detailModels[entry.id] = nil
        pushedGrids[entry.id] = nil
        rememberedPushedFocus[entry.id] = nil
        holdRail()
    }

    /// The root page, built only while its row is the destination.
    @ViewBuilder
    private var page: some View {
        switch nav.destination {
        case .search:
            TVSearchView(client: client, userID: userID, viewModel: search, rememberedResultID: $rememberedSearchResult)
        case .profile:
            TVProfileView()
        case .library(let id):
            if let library = libraries.first(where: { $0.id == id }), let grid = libraryGrids[id] {
                TVCollectionGridView(
                    title: library.name,
                    titleIdentifier: A11yID.TV.Library.title(library.id),
                    viewModel: grid,
                    rememberedItemID: Binding(
                        get: { rememberedLibraryItems[id] },
                        set: { rememberedLibraryItems[id] = $0 }
                    )
                )
            }
        default:
            TVBrowseLauncher(client: client, userID: userID, viewModel: home, rememberedTileKey: $rememberedHomeTile)
        }
    }

    /// Menu: pops a pushed page; on a root page, opens the sidebar on that
    /// page's row; with the sidebar open, nothing, so tvOS leaves the app.
    private var exitCommand: (() -> Void)? {
        if isExpanded { return nil }
        if !nav.path.isEmpty { return pop }
        return {
            railHeld = false
            Task { @MainActor in
                await Task.yield()
                focusedRow = nav.railAnchor(libraries: libraries)
            }
        }
    }

    /// Disables the sidebar until the page claims focus, or for at most
    /// three seconds. A page with nothing to focus (an empty library, a load
    /// that failed or is still running) would otherwise leave focus nowhere,
    /// where even Menu reaches nothing, so focus then goes to the page's row.
    private func holdRail() {
        railHeld = true
        holdGeneration += 1
        let generation = holdGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard generation == holdGeneration, railHeld else { return }
            railHeld = false
            // Nowhere, or left in the rail: holding it can push focus from
            // the chosen row onto another (seen: Profile's).
            guard Self.focusedItem() == nil || focusedRow != nil else { return }
            await Task.yield()
            let target = nav.enterRail(libraries: libraries)
            focusedRow = focusedRow == nil ? nav.railAnchor(libraries: libraries) : target
        }
    }

    private func releaseRail() {
        guard railHeld else { return }
        Task { @MainActor in
            await Task.yield()
            railHeld = false
        }
    }

    private func select(_ row: TVSidebarLayout.Row) {
        if case .library(let id) = row, libraryGrids[id] == nil,
           let library = libraries.first(where: { $0.id == id }) {
            libraryGrids[id] = CollectionGridViewModel(client: client, userID: userID, query: TVSidebarLayout.query(for: library))
        }
        if row != .librariesGroup {
            detailModels.values.forEach { $0.cancelBackgroundWork() }
            detailModels = [:]
            pushedGrids = [:]
            rememberedPushedFocus = [:]
        }
        let selection = withAnimation(.easeOut(duration: 0.2)) { nav.select(row) }
        guard selection == .navigated else { return }
        Task { @MainActor in
            // After the new page has laid out: Search's keyboard is a UIKit
            // control that isn't in the window until then, and holding the
            // sidebar sooner left focus nowhere to go.
            try? await Task.sleep(for: .milliseconds(150))
            holdRail()
            // Disabling a SwiftUI view doesn't make tvOS look for new focus by
            // itself; asking the focus system does, and with the sidebar held
            // it can only choose the page.
            await Task.yield()
            Self.requestFocusUpdate()
            focusHandoff += 1
        }
    }

    @MainActor
    private static func requestFocusUpdate() {
        guard let window = keyWindow(), let root = window.rootViewController,
              let focusSystem = UIFocusSystem.focusSystem(for: window) else { return }
        focusSystem.requestFocusUpdate(to: root)
        focusSystem.updateFocusIfNeeded()
    }

    @MainActor
    private static func focusedItem() -> UIFocusItem? {
        keyWindow().flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
    }

    @MainActor
    private static func keyWindow() -> UIWindow? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first(where: \.isKeyWindow)
    }
}
