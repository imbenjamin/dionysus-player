import SwiftUI

/// "Choose a Version" (#289): which of a title's files plays, as a page of
/// its own. A full-screen cover over the page that asked (Play, Restart, a
/// playlist row, the Home hero, the Top Shelf's Play), or, for auto-advance,
/// presented by the player host over the paused player.
///
/// A page, not iOS's dialog: a tvOS `confirmationDialog` puts its buttons in
/// a system sheet that can't take identifiers on tvOS 27 (as a `Menu`'s
/// submenu rows can't; `DionysusTV/CLAUDE.md`, More Actions), can't say
/// where focus starts, and reads poorly from across a room. This is
/// `TVConfirmation`'s and `TVAddToPlaylistPage`'s shape instead: the heading,
/// the title beneath it, one wide button a version.
///
/// Focus starts on the version marked "(Last Played)", else the first.
/// Menu answers nothing: in a cover the cover closes (and focus goes back to
/// the button that asked); over the player `onCancel` runs, which closes it.
struct TVVersionPickerPage: View {
    let title: String
    let choice: PendingVersionChoice
    let onChoose: (String) -> Void
    /// Menu, where the page isn't in a SwiftUI cover (the player host
    /// presents it with UIKit, and Menu must close the player). `nil` in a
    /// cover, which Menu closes by itself; a choice closes it too.
    var onCancel: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: String?

    /// The remembered version while it's still listed, else the first.
    static func initialFocusID(for choice: PendingVersionChoice) -> String? {
        let ids = choice.versions.map(\.id)
        if let lastPlayedID = choice.lastPlayedID, ids.contains(lastPlayedID) { return lastPlayedID }
        return ids.first
    }

    /// The server's own label ("4K HDR10", an edition's name) stays as it is;
    /// only the mark is localized, as iOS's dialog does.
    static func label(of version: MediaVersion, in choice: PendingVersionChoice) -> String {
        version.id == choice.lastPlayedID ? String(localized: "\(version.label) (Last Played)") : version.label
    }

    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 16) {
                Text("Choose a Version")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(A11yID.TV.versionPickerTitle)
                Text(verbatim: title)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }
            VStack(spacing: 24) {
                ForEach(choice.versions) { version in
                    Button {
                        onChoose(version.id)
                        if onCancel == nil { dismiss() }
                    } label: {
                        Text(verbatim: Self.label(of: version, in: choice))
                            .lineLimit(1)
                            .frame(width: 700)
                    }
                    .focused($focused, equals: version.id)
                    // The label may carry "(Last Played)" and is localized;
                    // the id is neither.
                    .accessibilityIdentifier(A11yID.TV.versionOption(version.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque enough that the page (or the paused picture) beneath doesn't
        // read through as part of the question, as `TVConfirmation`.
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focused, Self.initialFocusID(for: choice))
        .modifier(CancelOnMenu(onCancel: onCancel))
    }
}

/// Menu runs `onCancel` when there is one; otherwise it's left to the cover.
private struct CancelOnMenu: ViewModifier {
    let onCancel: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onCancel {
            content.onExitCommand(perform: onCancel)
        } else {
            content
        }
    }
}

/// A person's Play waiting on its version, on the Apple TV: set by the button
/// that was pressed and resolved by `tvVersionedPlayback(_:decide:remember:returnFocus:play:)`.
struct TVVersionedStart: Identifiable {
    enum Decision {
        /// Decide from the item (`MediaVersionResolver`, through the page's
        /// view model or the hero's own resolver): whether it has a resume
        /// point (`MediaItem.canResume`) is read from it, never from the
        /// button, so Restart on a part-watched title plays the remembered
        /// version as Resume does.
        case decide(MediaItem)
        /// Decided already: the Top Shelf's link (`linkVersionDecision`).
        case decided(MediaVersionChoice)
    }

    /// What a decision does to a start.
    enum Outcome: Equatable {
        case play(PlaybackRequest)
        case ask(versions: [MediaVersion], lastPlayedID: String?)
    }

    let id = UUID()
    /// The title the page names beneath its heading.
    let title: String
    /// What plays, but for its `mediaSourceID`, which the answer fills in.
    let request: PlaybackRequest
    let decision: Decision
    /// The focus id of the button that asked, given focus back when the
    /// question closes; `nil` where focus needs no help (the Top Shelf).
    let returnFocus: String?
    /// Set once the decision is to ask, while the page is up.
    fileprivate(set) var question: PendingVersionChoice?

    init(item: MediaItem, request: PlaybackRequest, returnFocus: String?) {
        self.title = item.name
        self.request = request
        self.decision = .decide(item)
        self.returnFocus = returnFocus
    }

    init(title: String, request: PlaybackRequest, decided: MediaVersionChoice, returnFocus: String? = nil) {
        self.title = title
        self.request = request
        self.decision = .decided(decided)
        self.returnFocus = returnFocus
    }

    static func outcome(of choice: MediaVersionChoice, request: PlaybackRequest) -> Outcome {
        switch choice {
        case .play(let mediaSourceID):
            var request = request
            request.mediaSourceID = mediaSourceID
            return .play(request)
        case .ask(let versions, let lastPlayedID):
            return .ask(versions: versions, lastPlayedID: lastPlayedID)
        }
    }
}

extension View {
    /// Plays `start` once its version is known, asking first on
    /// `TVVersionPickerPage` when it should (`MediaVersionChoice.decide`). An
    /// answer is remembered (`remember(mediaSourceID, itemID)`) and played
    /// once the page has closed (`TVConfirmation`'s rule: work runs from the
    /// cover's `onDismiss`, and the player can't present over a cover still
    /// going). Menu plays nothing and gives focus back to the button that
    /// asked.
    ///
    /// Keyed on the start, so a second press while a row's item is still
    /// being fetched replaces the first. A start whose decision is cut short
    /// (the view went away) or lands on a page no longer on show (one pushed
    /// over it) is dropped, never resumed: nothing plays without a fresh
    /// press, as on iOS (`VersionedPlaybackRun`).
    func tvVersionedPlayback(
        _ start: Binding<TVVersionedStart?>,
        decide: @escaping (MediaItem, _ isResume: Bool) async -> MediaVersionChoice,
        remember: @escaping (_ mediaSourceID: String, _ itemID: String) -> Void,
        focus: FocusState<String?>.Binding?,
        play: @escaping (PlaybackRequest) -> Void
    ) -> some View {
        modifier(TVVersionedPlaybackModifier(
            start: start, decide: decide, remember: remember, focus: focus, play: play
        ))
    }
}

private struct TVVersionedPlaybackModifier: ViewModifier {
    @Binding var start: TVVersionedStart?
    let decide: (MediaItem, Bool) async -> MediaVersionChoice
    let remember: (String, String) -> Void
    /// The page's focus, for `TVVersionedStart.returnFocus`; `nil` where
    /// there's none to return to.
    let focus: FocusState<String?>.Binding?
    let play: (PlaybackRequest) -> Void

    @Environment(\.tvPageIsOnShow) private var isOnShow
    @Environment(\.tvPageClaimingFocus) private var holdRail
    @Environment(\.tvPageClaimedFocus) private var releaseRail
    /// The start whose page is closing, read by `onDismiss`.
    @State private var closing: TVVersionedStart?
    /// The version chosen on the page, played once it has closed.
    @State private var answer: String?

    /// The start while its question is up; cleared (Menu, or a choice's own
    /// dismiss) it moves to `closing` for `onDismiss`.
    private var asking: Binding<TVVersionedStart?> {
        Binding(
            get: { start?.question == nil ? nil : start },
            set: { newValue in
                guard newValue == nil, start?.question != nil else { return }
                closing = start
                start = nil
                // Closed by code (a choice), tvOS gave focus to the rail and
                // opened it, as More Actions found: held until focus is back.
                holdRail()
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .task(id: start?.id) { await decideStart() }
            .fullScreenCover(item: asking, onDismiss: questionClosed) { pending in
                if let question = pending.question {
                    TVVersionPickerPage(title: pending.title, choice: question) { answer = $0 }
                }
            }
    }

    private func decideStart() async {
        guard let pending = start, pending.question == nil else { return }
        let choice: MediaVersionChoice
        switch pending.decision {
        case .decided(let decided): choice = decided
        case .decide(let item): choice = await decide(item, item.canResume)
        }
        guard start?.id == pending.id else { return }
        guard !Task.isCancelled, isOnShow else {
            // Dropped, not kept for later: a return to the page mustn't play
            // what nobody pressed for again.
            start = nil
            return
        }
        switch TVVersionedStart.outcome(of: choice, request: pending.request) {
        case .play(let request):
            start = nil
            play(request)
        case .ask(let versions, let lastPlayedID):
            start?.question = PendingVersionChoice(versions: versions, lastPlayedID: lastPlayedID)
        }
    }

    private func questionClosed() {
        let closed = closing
        let chosen = answer
        closing = nil
        answer = nil
        guard let closed else { return releaseRail() }
        if let chosen {
            remember(chosen, closed.request.itemID)
            var request = closed.request
            request.mediaSourceID = chosen
            play(request)
        }
        // Back to the button that asked, as More Actions does after its
        // covers: set until it holds, then the rail is free again. Under a
        // player just presented this lands on the page beneath, where Menu
        // will return.
        Task { @MainActor in
            if let focus, let focusID = closed.returnFocus {
                for _ in 0..<20 {
                    focus.wrappedValue = focusID
                    try? await Task.sleep(for: .milliseconds(50))
                    if focus.wrappedValue == focusID { break }
                }
            }
            releaseRail()
        }
    }
}
