import XCTest
@testable import Dionysus

/// Whether a start counts as a resume comes from the title, never the button
/// (Benjamin, 2026-11-13): Restart on a part-watched title plays the
/// remembered version just as Resume does, and only its start position
/// differs. iOS-only, as `VersionChoiceDialog.swift` is.
@MainActor
final class VersionedPlaybackStartTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok")

    private func isResume(_ start: VersionedPlaybackStart) -> Bool? {
        guard case .start(_, let isResume) = start.kind else { return nil }
        return isResume
    }

    func test_restart_withResumePoint_countsAsResume() {
        let dto = BaseItemDto(
            id: "movie-2", name: "Signal Fire", type: .movie,
            userData: UserItemDataDto(playbackPositionTicks: 600 * 10_000_000, playedPercentage: 20, played: false)
        )
        let item = MediaItem(dto: dto, images: images)
        let start = VersionedPlaybackStart.start(
            item, request: PlaybackRequest(itemID: "movie-2", startFromBeginning: true), anchor: .restartButton
        )
        XCTAssertEqual(isResume(start), true)
        XCTAssertEqual(start.request.startFromBeginning, true, "Restart still starts from 0")
        XCTAssertEqual(start.anchor, .restartButton)
    }

    func test_play_withoutResumePoint_isAFreshStart() {
        let item = MediaItem(dto: BaseItemDto(id: "movie-1", name: "The Quiet Ascent", type: .movie), images: images)
        let start = VersionedPlaybackStart.start(item, request: PlaybackRequest(itemID: "movie-1"), anchor: .playButton)
        XCTAssertEqual(isResume(start), false)
    }

    // MARK: VersionedPlaybackRun

    /// The page's state a pass reads and writes, and what it played.
    private final class PageState {
        var start: VersionedPlaybackStart?
        var played: [PlaybackRequest] = []
        var decisions = 0
        /// Remembered picks, item id to source id.
        var remembered: [String: String] = [:]
    }

    private func run(_ page: PageState, decide: @escaping (VersionedPlaybackStart) async -> MediaVersionChoice) -> VersionedPlaybackRun {
        VersionedPlaybackRun(
            anchor: .page,
            getStart: { page.start },
            setStart: { page.start = $0 },
            decide: { pending in
                page.decisions += 1
                return await decide(pending)
            },
            remember: { mediaSourceID, itemID in page.remembered[itemID] = mediaSourceID },
            play: { page.played.append($0) }
        )
    }

    /// A row's start is decided by the page (its row can be torn down by a
    /// lazy list mid-fetch) but asks from the row: the question it sets keeps
    /// the row's anchor, so only that row's Play presents it.
    func test_run_rowStart_isDecidedByThePage_andKeepsItsRowAnchor() async {
        let page = PageState()
        let item = MediaItem(dto: BaseItemDto(id: "ep-2", name: "Two", type: .episode), images: images)
        page.start = .start(item, request: PlaybackRequest(itemID: "ep-2"), anchor: .row("ep-2"))

        await run(page) { _ in
            .ask(versions: [MediaVersion(id: "a", label: "A"), MediaVersion(id: "b", label: "B")], lastPlayedID: nil)
        }.run()

        XCTAssertEqual(page.decisions, 1, "The page's pass decides a row's start")
        XCTAssertNotNil(page.start?.question)
        XCTAssertEqual(page.start?.anchor, .row("ep-2"), "The question stays the row's to show")
        XCTAssertEqual(VersionedPlaybackStart.Anchor.row("ep-2").decidingAnchor, .page)
        XCTAssertEqual(VersionedPlaybackStart.Anchor.playButton.decidingAnchor, .playButton)
    }

    /// A Play button's start isn't the page's to decide.
    func test_run_playButtonStart_isLeftToItsButton() async {
        let page = PageState()
        let item = MediaItem(dto: BaseItemDto(id: "movie-1", name: "One", type: .movie), images: images)
        page.start = .start(item, request: PlaybackRequest(itemID: "movie-1"), anchor: .playButton)

        await run(page) { _ in .play(mediaSourceID: "x") }.run()

        XCTAssertEqual(page.decisions, 0)
        XCTAssertTrue(page.played.isEmpty)
    }

    /// Auto-advance carried a version on: it plays, and is remembered as if
    /// chosen, so a later Resume of that episode doesn't ask about it.
    func test_run_continuationCarriesAVersionOn_remembersIt() async {
        let page = PageState()
        page.start = .continuation(nil, request: PlaybackRequest(itemID: "ep-3", previousVersionLabel: "1080p"))

        await run(page) { _ in .play(mediaSourceID: "ep-3-1080p") }.run()

        XCTAssertEqual(page.played.map(\.mediaSourceID), ["ep-3-1080p"])
        XCTAssertEqual(page.remembered, ["ep-3": "ep-3-1080p"])
    }

    /// Nothing is remembered for a single-version next item (the server's
    /// default plays), nor for a person's start that plays without asking:
    /// that pick was already the remembered one.
    func test_run_singleVersionContinuation_orAPersonsStart_remembersNothing() async {
        let page = PageState()
        page.start = .continuation(.play(mediaSourceID: nil), request: PlaybackRequest(itemID: "ep-3"))
        await run(page) { _ in .play(mediaSourceID: nil) }.run()

        page.start = rowStart()
        await run(page) { _ in .play(mediaSourceID: "ep-2-1080p") }.run()

        XCTAssertEqual(page.played.count, 2)
        XCTAssertTrue(page.remembered.isEmpty)
    }

    private func rowStart() -> VersionedPlaybackStart {
        let item = MediaItem(dto: BaseItemDto(id: "ep-2", name: "Two", type: .episode), images: images)
        return .start(item, request: PlaybackRequest(itemID: "ep-2"))
    }

    func test_run_decided_playsTheVersion_andEndsTheStart() async {
        let page = PageState()
        page.start = rowStart()

        await run(page) { _ in .play(mediaSourceID: "ep-2-1080p") }.run()

        XCTAssertEqual(page.played.map(\.mediaSourceID), ["ep-2-1080p"])
        XCTAssertNil(page.start)
    }

    /// The view went away while a row's item was still being fetched (a page
    /// pushed over it, a tab switch): nothing plays then, and nothing plays
    /// when the view comes back and its `.task` runs again. Only a fresh tap
    /// may start playback.
    func test_run_cancelledMidDecision_dropsTheStart_andNothingPlaysOnReappear() async {
        let page = PageState()
        page.start = rowStart()
        let slowDecision = run(page) { _ in
            // A slow server: cancelled, as `.task` is when its view goes.
            try? await Task.sleep(for: .seconds(30))
            return .play(mediaSourceID: "ep-2-1080p")
        }

        let task = Task { await slowDecision.run() }
        try? await waitUntil { page.decisions == 1 }
        task.cancel()
        await task.value

        XCTAssertTrue(page.played.isEmpty, "Nothing plays as the view goes")
        XCTAssertEqual(page.start?.wasInterrupted, true)

        // The view comes back: `.task(id:)` runs again with the same start.
        await run(page) { _ in .play(mediaSourceID: "ep-2-1080p") }.run()

        XCTAssertTrue(page.played.isEmpty, "Nothing plays on the way back without a tap")
        XCTAssertNil(page.start, "The interrupted start is dropped")
        XCTAssertEqual(page.decisions, 1, "It isn't decided again")
    }

    /// A question already up survives a pass (a reset of the view by the
    /// page's `.id` runs `.task` again) and isn't decided twice.
    func test_run_questionAlreadyUp_isLeftAlone() async {
        let page = PageState()
        page.start = rowStart()
        await run(page) { _ in .ask(versions: [MediaVersion(id: "a", label: "A"), MediaVersion(id: "b", label: "B")], lastPlayedID: nil) }.run()
        XCTAssertNotNil(page.start?.question)

        await run(page) { _ in .play(mediaSourceID: "a") }.run()

        XCTAssertNotNil(page.start?.question)
        XCTAssertTrue(page.played.isEmpty)
        XCTAssertEqual(page.decisions, 1)
    }

    /// Finished titles have no resume point, so Play asks again, marking the
    /// remembered version.
    func test_play_finishedTitle_isAFreshStart() {
        let dto = BaseItemDto(
            id: "movie-1", name: "The Quiet Ascent", type: .movie,
            userData: UserItemDataDto(playbackPositionTicks: 0, playedPercentage: 100, played: true)
        )
        let start = VersionedPlaybackStart.start(MediaItem(dto: dto, images: images), request: PlaybackRequest(itemID: "movie-1"))
        XCTAssertEqual(isResume(start), false)
        XCTAssertEqual(start.anchor, .page)
    }
}
