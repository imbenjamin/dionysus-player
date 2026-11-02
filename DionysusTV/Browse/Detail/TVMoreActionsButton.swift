import SwiftUI

/// More Actions, after Favorite on a movie's and a show's page (Benjamin,
/// 2026-10-21): iOS's Add to Playlist and Delete, offering the same targets
/// in the same words (`AssetActionTargets`). Always drawn, since adding to a
/// playlist has no permission gate, so the button never changes kind once
/// `CanDelete` arrives with the full item.
///
/// **A system `Menu`, then the app's own pages** (Benjamin chose this hybrid,
/// 2026-10-21, over a full-screen list and over the menu throughout): the
/// menu drops from the button as the TV app's "…" does, with iOS's shape (a
/// lone target is a row, several a submenu naming each; Delete last, below a
/// divider). Choosing Add to Playlist opens the picker
/// (`TVAddToPlaylistPage`) and Delete its question (`TVConfirmation`), each a
/// full-screen cover Menu closes onto this button. Only the picker loads
/// playlists, so a page that never opens it costs no request.
///
/// **The menu gives focus back about 1.3 s after Menu closes it** (1.28 s
/// measured on the tvOS 27 Simulator with animations on, against 0.61 s for
/// a cover; 0.27 s for both under the UI-test harness, which turns
/// animations off), with nothing focused between: the system menu's own
/// timing, accepted here for the native look.
struct TVMoreActionsButton: View {
    let viewModel: AssetDetailViewModel
    let targets: AssetActionTargets
    let focus: FocusState<String?>.Binding

    @Environment(\.tvPopPage) private var popPage
    @Environment(\.tvPopToRoot) private var popToRoot
    @Environment(\.tvPageClaimingFocus) private var holdRail
    @Environment(\.tvPageClaimedFocus) private var releaseRail
    @State private var cover: TVMoreActionsCover?
    /// Confirmed, and deleted once the question has gone, so a pop never
    /// lands while its cover is still dismissing.
    @State private var confirmedDeletion: MediaItem?
    @State private var errorMessage: String?

    private var isPending: Bool { !viewModel.deletingItemIDs.isEmpty }

    var body: some View {
        Menu {
            addContent
            if !targets.deletable.isEmpty {
                // Destructive last and set apart, as on iOS.
                Divider()
                deleteContent
            }
        } label: {
            Image(systemName: "ellipsis")
                .opacity(isPending ? 0 : 1)
                .overlay { if isPending { ProgressView() } }
        }
        .focused(focus, equals: TVDetailFocus.more)
        .accessibilityLabel(String(localized: "More Actions"))
        .accessibilityIdentifier(A11yID.TV.Detail.more)
        .fullScreenCover(item: $cover, onDismiss: coverDismissed) { cover in
            switch cover {
            case .playlist(let target):
                NavigationStack {
                    TVAddToPlaylistPage(
                        client: viewModel.apiClient, userID: viewModel.currentUserID,
                        target: target, close: { self.cover = nil }
                    )
                }
            case .confirmDelete(let target):
                // Its own `dismiss()` closes the cover, onto More.
                TVConfirmation(
                    title: Text(verbatim: AssetActionTargets.deleteActionLabel(for: target)),
                    message: Text(verbatim: AssetActionTargets.deleteConfirmationMessage(for: target)),
                    action: Text("Delete"),
                    actionIdentifier: A11yID.TV.Actions.deleteConfirm
                ) { confirmedDeletion = target }
            }
        }
        // Closed by code (an add, a create), tvOS gave focus to the rail and
        // opened it, animations on. Held from the moment the cover starts to
        // go until More has focus again (Menu closing it never did this).
        .onChange(of: cover == nil) { _, closed in
            if closed { holdRail() }
        }
        .alert(
            "Couldn't delete",
            isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var addContent: some View {
        if targets.addable.count == 1, let only = targets.addable.first {
            addRow(only, title: String(localized: "Add to Playlist"))
        } else {
            Menu {
                ForEach(targets.addable, id: \.id) { target in
                    addRow(target, title: AssetActionTargets.rowLabel(for: target))
                }
            } label: {
                Label(String(localized: "Add to Playlist"), systemImage: "text.badge.plus")
                    .accessibilityIdentifier(A11yID.TV.Actions.addSubmenu)
            }
        }
    }

    private func addRow(_ target: MediaItem, title: String) -> some View {
        Button { cover = .playlist(target) } label: {
            Label(title, systemImage: "text.badge.plus")
        }
        .accessibilityIdentifier(A11yID.TV.Actions.addToPlaylist(target.id))
    }

    @ViewBuilder
    private var deleteContent: some View {
        if targets.deletable.count == 1, let only = targets.deletable.first {
            deleteRow(only, title: AssetActionTargets.deleteActionLabel(for: only))
        } else {
            Menu {
                ForEach(targets.deletable, id: \.id) { target in
                    deleteRow(target, title: AssetActionTargets.rowLabel(for: target))
                }
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
                    .accessibilityIdentifier(A11yID.TV.Actions.deleteSubmenu)
            }
        }
    }

    private func deleteRow(_ target: MediaItem, title: String) -> some View {
        Button(role: .destructive) {
            // Ignored rather than disabled while a deletion runs.
            guard !isPending else { return }
            cover = .confirmDelete(target)
        } label: {
            Label(title, systemImage: "trash")
        }
        .accessibilityIdentifier(A11yID.TV.Actions.delete(target.id))
    }

    private func coverDismissed() {
        if let target = confirmedDeletion {
            confirmedDeletion = nil
            delete(target)
        }
        Task { @MainActor in
            for _ in 0..<20 {
                focus.wrappedValue = TVDetailFocus.more
                try? await Task.sleep(for: .milliseconds(50))
                if focus.wrappedValue == TVDetailFocus.more { break }
            }
            releaseRail()
        }
    }

    /// Runs once the question has closed. A bare `Task`, as on iOS
    /// (`AssetActionsButton.perform`): the deletion often ends by popping this
    /// page, which must not cancel the request causing it.
    private func delete(_ target: MediaItem) {
        Task {
            do {
                switch try await viewModel.delete(target) {
                case .stayAndRefresh: break
                case .popOneLevel: popPage()
                case .popToRoot: popToRoot()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// What a choice in More Actions' menu opens.
private enum TVMoreActionsCover: Identifiable {
    case playlist(MediaItem)
    case confirmDelete(MediaItem)

    var id: String {
        switch self {
        case .playlist(let item): "playlist.\(item.id)"
        case .confirmDelete(let item): "delete.\(item.id)"
        }
    }
}
