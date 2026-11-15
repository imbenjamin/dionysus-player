import SwiftUI

extension View {
    /// The "Choose a Version" question (#289), shown while `pending` is
    /// non-nil: one button per version, the remembered one marked
    /// "(Last Played)" (D8). Choosing calls `onChoose` with the version's
    /// `MediaVersion.id`; Cancel, or tapping outside, clears `pending` and
    /// calls nothing. Every iOS play entry point asks through this one dialog
    /// (`versionedPlayback(_:anchor:viewModel:play:)`), and so will the single
    /// download's question.
    func versionChoiceDialog(
        _ pending: Binding<PendingVersionChoice?>, onChoose: @escaping (String) -> Void
    ) -> some View {
        modifier(VersionChoiceDialogModifier(pending: pending, onChoose: onChoose))
    }

    /// Starts playback once `start`'s version is known, asking first when
    /// it should (`MediaVersionChoice`): set `start` and this decides,
    /// shows `versionChoiceDialog` when the answer is "ask", remembers the
    /// answer (`AssetDetailViewModel.setPreferredMediaSourceID`, which a title
    /// with a resume point then plays without asking) and hands `play` the
    /// request with its `mediaSourceID` filled in. A dismissed question plays
    /// nothing.
    ///
    /// The question is a popover anchored to the view this modifies, so it
    /// points at what was tapped: only a start whose `anchor` matches is
    /// handled here. `PlayResumeButtonRow` applies it to its Play and Restart
    /// buttons (an arrow at Resume after a Restart tap read as Resume asking);
    /// a page applies it once more, with `.page`, which decides its list
    /// rows' starts and auto-advance's and asks auto-advance's question. A
    /// row's question is asked from the row's own Play
    /// (`versionQuestionAnchor(rowID:)`), so on iPad its popover points at
    /// the row tapped rather than the page. Every bit of state lives in
    /// `start`, on the page, so a view reset by the page's
    /// `.id(refreshTrigger)` (bumped as the player closes, and again when the
    /// refresh lands) shows the same question again rather than dropping it.
    func versionedPlayback(
        _ start: Binding<VersionedPlaybackStart?>,
        anchor: VersionedPlaybackStart.Anchor,
        viewModel: AssetDetailViewModel,
        play: @escaping (PlaybackRequest) -> Void
    ) -> some View {
        modifier(VersionedPlaybackModifier(start: start, anchor: anchor, viewModel: viewModel, play: play))
    }

    /// `versionedPlayback(_:anchor:viewModel:play:)` with `host`'s page state.
    func versionedPlayback(_ host: VersionedPlaybackHost, anchor: VersionedPlaybackStart.Anchor) -> some View {
        versionedPlayback(host.start, anchor: anchor, viewModel: host.viewModel, play: host.play)
    }

    /// Asks a list row's version question from this view, the row's Play, so
    /// on iPad the popover points at the row tapped (on iPhone the dialog
    /// rises from the bottom whatever its anchor). Only the question moves
    /// here: the page's `.page` `versionedPlayback` still decides the start
    /// (`.row` starts included), since a row in a lazy list can be torn down
    /// mid-fetch and its decision must outlive it. Reads the page's state
    /// from `\.versionedRowHost`; with none, it does nothing.
    func versionQuestionAnchor(rowID: String) -> some View {
        modifier(VersionQuestionRowModifier(rowID: rowID))
    }
}

extension EnvironmentValues {
    /// The page's row-play state, for `versionQuestionAnchor(rowID:)`: set by
    /// a detail page on its list of rows, `nil` everywhere else.
    @Entry var versionedRowHost: VersionedPlaybackHost?
}

/// What a page hands `PlayResumeButtonRow`, and its list rows through
/// `\.versionedRowHost`, so the version question can anchor to the button
/// tapped while its state stays on the page (see
/// `versionedPlayback(_:anchor:viewModel:play:)`).
struct VersionedPlaybackHost {
    let start: Binding<VersionedPlaybackStart?>
    let viewModel: AssetDetailViewModel
    let play: (PlaybackRequest) -> Void
}

/// A play waiting on its version: set on a page's `@State` by a Play, Resume
/// or Restart tap, or by auto-advance, and resolved by
/// `versionedPlayback(_:anchor:viewModel:play:)`.
struct VersionedPlaybackStart: Identifiable {
    /// Which view the question points at.
    enum Anchor: Equatable {
        /// `PlayResumeButtonRow`'s Play/Resume button.
        case playButton
        /// `PlayResumeButtonRow`'s Restart button.
        case restartButton
        /// The page: auto-advance, which has no row to point at.
        case page
        /// A list row's Play, keyed as the row is (an episode's or a
        /// collection member's id, a playlist entry's `playlistItemID`, since
        /// a playlist can hold one title twice). Decided by the page's
        /// `.page` modifier, asked from the row (`versionQuestionAnchor`).
        case row(String)

        /// The `versionedPlayback` anchor that decides a start with this
        /// anchor: the page's, for a row.
        var decidingAnchor: Anchor {
            if case .row = self { return .page }
            return self
        }
    }

    enum Kind {
        /// A person's tap: `MediaVersionChoice.decide`, over `item`'s sources
        /// (fetched if a listing left them out). `isResume` is whether the
        /// title has a resume point (`MediaItem.canResume`), whichever button
        /// was tapped: Restart on a part-watched title plays the remembered
        /// version just as Resume does, and only the start position differs
        /// (Benjamin, 2026-11-13).
        case start(item: MediaItem, isResume: Bool)
        /// Auto-advance (D2): the player's own decision for the next item
        /// (`PlayerViewModel.nextItemVersionChoice`) when it had one, else
        /// `nil` to decide afresh from `request.previousVersionLabel`
        /// (`MediaVersionChoice.continuation`), never "play the default".
        case continuation(handedOver: MediaVersionChoice?)
    }

    let id = UUID()
    let kind: Kind
    /// What plays, but for its `mediaSourceID`, which the decision fills in.
    let request: PlaybackRequest
    let anchor: Anchor
    /// Set once the decision is to ask, while the question is up.
    fileprivate(set) var question: PendingVersionChoice?
    /// Set when the view deciding it went away mid-decision (a page pushed
    /// over it, a tab switch): the start is then dropped, never resumed, so
    /// nothing plays on the way back without a fresh tap.
    fileprivate(set) var wasInterrupted = false

    /// A person's Play, Resume or Restart of `item` (or a row's Play). Whether
    /// it counts as a resume is read from `item` here, never from the button,
    /// so no caller can make Restart ask on a part-watched title.
    static func start(_ item: MediaItem, request: PlaybackRequest, anchor: Anchor = .page) -> Self {
        Self(kind: .start(item: item, isResume: item.canResume), request: request, anchor: anchor)
    }

    static func continuation(_ handedOver: MediaVersionChoice?, request: PlaybackRequest) -> Self {
        Self(kind: .continuation(handedOver: handedOver), request: request, anchor: .page)
    }
}

private struct VersionChoiceDialogModifier: ViewModifier {
    @Binding var pending: PendingVersionChoice?
    let onChoose: (String) -> Void

    /// A plain `@State Bool` driven by `pending`, not a computed `Binding`
    /// derived from it being non-`nil`. The two read as equivalent, but a
    /// computed `Binding` as `confirmationDialog`'s `isPresented` was
    /// unreliable across repeated presentations (in `PlayResumeButtonRow`,
    /// where this dialog started): the third or fourth Play in one session
    /// silently skipped the question and played the server's default. A
    /// stored `@State` projected directly is the documented pattern and
    /// didn't reproduce it.
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: pending?.id, initial: true) {
                isPresented = pending != nil
            }
            .onChange(of: isPresented) { _, presented in
                if !presented { pending = nil }
            }
            .confirmationDialog(
                "Choose a Version", isPresented: $isPresented, titleVisibility: .visible, presenting: pending
            ) { choice in
                ForEach(choice.versions) { version in
                    Button(title(of: version, in: choice)) { onChoose(version.id) }
                        // The label may carry "(Last Played)" and is
                        // localized; the id is neither.
                        .accessibilityIdentifier(A11yID.Versions.option(version.id))
                }
            }
    }

    /// The version's own label stays as the server named it (an edition or
    /// "4K HDR10"); only the mark is localized.
    private func title(of version: MediaVersion, in choice: PendingVersionChoice) -> String {
        version.id == choice.lastPlayedID ? String(localized: "\(version.label) (Last Played)") : version.label
    }
}

private struct VersionedPlaybackModifier: ViewModifier {
    @Binding var start: VersionedPlaybackStart?
    let anchor: VersionedPlaybackStart.Anchor
    let viewModel: AssetDetailViewModel
    let play: (PlaybackRequest) -> Void

    /// `start`, when it's this anchor's to decide: its own, and on the page
    /// every row's too.
    private var ownStart: VersionedPlaybackStart? {
        start?.anchor.decidingAnchor == anchor ? start : nil
    }

    func body(content: Content) -> some View {
        content
            // Keyed on the start, so a second tap while a row's item is still
            // being fetched replaces the first rather than playing both. Runs
            // again after a reset of this view, and leaves a question already
            // asked alone.
            .task(id: ownStart?.id) {
                await VersionedPlaybackRun(
                    anchor: anchor,
                    getStart: { start },
                    setStart: { start = $0 },
                    decide: decide,
                    remember: { mediaSourceID, itemID in
                        viewModel.setPreferredMediaSourceID(mediaSourceID, forPlayableItem: itemID)
                    },
                    play: play
                ).run()
            }
            .modifier(VersionQuestionModifier(start: $start, anchor: anchor, viewModel: viewModel, play: play))
    }

    private func decide(_ pending: VersionedPlaybackStart) async -> MediaVersionChoice {
        switch pending.kind {
        case .start(let item, let isResume):
            return await viewModel.playbackDecision(for: item, isResume: isResume)
        case .continuation(let handedOver?):
            return handedOver
        case .continuation(nil):
            return await viewModel.continuationDecision(
                forItemID: pending.request.itemID, previousVersionLabel: pending.request.previousVersionLabel
            )
        }
    }
}

/// The question of a start anchored exactly at `anchor`, shown from the view
/// this modifies: its answer is remembered
/// (`AssetDetailViewModel.setPreferredMediaSourceID`) and played; clearing it
/// (Cancel, a tap outside, or the answer) ends the start.
private struct VersionQuestionModifier: ViewModifier {
    @Binding var start: VersionedPlaybackStart?
    let anchor: VersionedPlaybackStart.Anchor
    let viewModel: AssetDetailViewModel
    let play: (PlaybackRequest) -> Void

    private var question: Binding<PendingVersionChoice?> {
        Binding(
            get: { start?.anchor == anchor ? start?.question : nil },
            set: { if $0 == nil, start?.anchor == anchor { start = nil } }
        )
    }

    func body(content: Content) -> some View {
        content.versionChoiceDialog(question) { mediaSourceID in
            guard let pending = start, pending.anchor == anchor else { return }
            var request = pending.request
            start = nil
            viewModel.setPreferredMediaSourceID(mediaSourceID, forPlayableItem: request.itemID)
            request.mediaSourceID = mediaSourceID
            play(request)
        }
    }
}

/// `versionQuestionAnchor(rowID:)`: the row's question, from the page's state
/// in the environment.
private struct VersionQuestionRowModifier: ViewModifier {
    let rowID: String
    @Environment(\.versionedRowHost) private var host

    func body(content: Content) -> some View {
        if let host {
            content.modifier(VersionQuestionModifier(
                start: host.start, anchor: .row(rowID), viewModel: host.viewModel, play: host.play
            ))
        } else {
            content
        }
    }
}

/// One pass of `versionedPlayback`'s decision, apart from the view so its
/// lifecycle rules are testable (`VersionedPlaybackStartTests`). Run from
/// `.task(id:)`, keyed on the start, so a second tap while a row's item is
/// still being fetched replaces the first rather than playing both, and it
/// runs again when the view reappears or is reset by the page's `.id`.
///
/// A pass cancelled mid-decision (the view went away: a page pushed over it
/// from a row's title, a tab switch) marks the start interrupted, and the
/// next pass drops it rather than deciding again: the fetch for a row's item
/// can take seconds on a slow server, and playing on return, with no tap,
/// would be a surprise. A question already up is left alone, to be shown
/// again after a reset.
@MainActor
struct VersionedPlaybackRun {
    let anchor: VersionedPlaybackStart.Anchor
    let getStart: () -> VersionedPlaybackStart?
    let setStart: (VersionedPlaybackStart?) -> Void
    let decide: (VersionedPlaybackStart) async -> MediaVersionChoice
    /// Stores a version as the title's remembered pick (`mediaSourceID`,
    /// then the item id), for a version auto-advance carried on.
    let remember: (String, String) -> Void
    let play: (PlaybackRequest) -> Void

    func run() async {
        guard let pending = getStart(), pending.anchor.decidingAnchor == anchor, pending.question == nil else { return }
        if pending.wasInterrupted {
            setStart(nil)
            return
        }
        let choice = await decide(pending)
        guard var current = getStart(), current.id == pending.id else { return }
        if Task.isCancelled {
            current.wasInterrupted = true
            setStart(current)
            return
        }
        switch choice {
        case .play(let mediaSourceID):
            setStart(nil)
            // A version auto-advance carried on (the remembered pick, or the
            // label just watched) is remembered as if chosen, on both
            // platforms (`TVPlayerHostController.advance(to:mediaSourceID:)`):
            // otherwise a later Resume of this episode, with nothing
            // remembered, asks about the version it was watched in. A
            // concrete id comes only from a title with two or more versions
            // (`MediaVersionChoice.continuation`); a person's start is
            // remembered by its question's answer alone, and a link never
            // gets here.
            if case .continuation = pending.kind, let mediaSourceID {
                remember(mediaSourceID, pending.request.itemID)
            }
            var request = pending.request
            request.mediaSourceID = mediaSourceID
            play(request)
        case .ask(let versions, let lastPlayedID):
            current.question = PendingVersionChoice(versions: versions, lastPlayedID: lastPlayedID)
            setStart(current)
        }
    }
}
