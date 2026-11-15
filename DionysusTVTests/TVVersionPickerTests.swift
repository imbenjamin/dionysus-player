import UIKit
import XCTest
@testable import Dionysus

/// The Apple TV's version question (#289): the page's focus and labels, what
/// a decision does to a start, and what auto-advance does with the player's
/// own decision for the next item.
@MainActor
final class TVVersionPickerTests: XCTestCase {
    private let versions = [
        MediaVersion(id: "movie-01-4k", label: "4K HDR10"),
        MediaVersion(id: "movie-01-1080p", label: "1080p"),
    ]

    // MARK: - The page

    func test_focusStartsOnTheLastPlayedVersion() {
        let choice = PendingVersionChoice(versions: versions, lastPlayedID: "movie-01-1080p")
        XCTAssertEqual(TVVersionPickerPage.initialFocusID(for: choice), "movie-01-1080p")
    }

    func test_focusStartsOnTheFirstVersion_withNothingMarked() {
        XCTAssertEqual(TVVersionPickerPage.initialFocusID(for: PendingVersionChoice(versions: versions, lastPlayedID: nil)), "movie-01-4k")
        // A stale mark (not among the versions) marks nothing.
        XCTAssertEqual(TVVersionPickerPage.initialFocusID(for: PendingVersionChoice(versions: versions, lastPlayedID: "gone")), "movie-01-4k")
    }

    func test_label_marksOnlyTheLastPlayedVersion() {
        let choice = PendingVersionChoice(versions: versions, lastPlayedID: "movie-01-1080p")
        XCTAssertEqual(TVVersionPickerPage.label(of: versions[0], in: choice), "4K HDR10")
        XCTAssertEqual(TVVersionPickerPage.label(of: versions[1], in: choice), "1080p (Last Played)")
    }

    // MARK: - A start's decision

    func test_aDecisionToPlay_fillsInTheVersion() {
        let request = PlaybackRequest(itemID: "movie-01", startFromBeginning: true)
        let outcome = TVVersionedStart.outcome(of: .play(mediaSourceID: "movie-01-1080p"), request: request)
        XCTAssertEqual(outcome, .play(PlaybackRequest(itemID: "movie-01", startFromBeginning: true, mediaSourceID: "movie-01-1080p")))
    }

    func test_aDecisionToPlayTheDefault_leavesTheVersionToTheServer() {
        let outcome = TVVersionedStart.outcome(of: .play(mediaSourceID: nil), request: PlaybackRequest(itemID: "movie-01"))
        XCTAssertEqual(outcome, .play(PlaybackRequest(itemID: "movie-01")))
    }

    func test_aDecisionToAsk_asksWithTheMark() {
        let outcome = TVVersionedStart.outcome(
            of: .ask(versions: versions, lastPlayedID: "movie-01-4k"), request: PlaybackRequest(itemID: "movie-01")
        )
        XCTAssertEqual(outcome, .ask(versions: versions, lastPlayedID: "movie-01-4k"))
    }

    // MARK: - The question over the player

    /// A refused presentation is reported, so the host can give the player
    /// back rather than leave it paused under a question that never showed.
    func test_overPlayer_aRefusedPresentation_isReported() {
        let player = UIViewController() // in no window: UIKit refuses
        let question = UIViewController()
        XCTAssertFalse(TVOverPlayerPresentation.present(question, over: player))
        XCTAssertNil(question.presentingViewController)
    }

    func test_overPlayer_presentsOnTopOfWhatThePlayerPresented() throws {
        // A window with no scene never shows, and UIKit refuses to present in it.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let player = UIViewController()
        window.rootViewController = player
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let layer = UIViewController()
        player.present(layer, animated: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(layer.presentingViewController === player, "The window takes presentations")
        let question = UIViewController()

        XCTAssertTrue(TVOverPlayerPresentation.present(question, over: player))
        XCTAssertTrue(question.presentingViewController === layer, "Over the layer, not beside it")
    }

    // MARK: - Auto-advance (D2)

    func test_nextItem_handedOverPlay_playsThatVersion() {
        XCTAssertEqual(TVNextItemVersionStep(handedOver: .play(mediaSourceID: "episode-s2e2-original")), .play(mediaSourceID: "episode-s2e2-original"))
    }

    func test_nextItem_handedOverAsk_asksOverThePlayer() {
        XCTAssertEqual(
            TVNextItemVersionStep(handedOver: .ask(versions: versions, lastPlayedID: nil)),
            .ask(versions: versions, lastPlayedID: nil)
        )
    }

    /// Nothing handed over (the next item's fetch hadn't landed, or failed)
    /// is decided afresh, never "play the server's default".
    func test_nextItem_nothingHandedOver_decidesAfresh() {
        XCTAssertEqual(TVNextItemVersionStep(handedOver: nil), .decideAfresh)
    }

    /// A version auto-advance carried on is remembered as the next item's
    /// pick, as one chosen on the question is, so a later Resume of that
    /// episode plays it without asking; a single-version item (`nil`, the
    /// server's default) remembers nothing.
    func test_advance_remembersACarriedOnVersion_only() {
        let client = JellyfinAPIClient(
            baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()
        )
        func viewModel(_ itemID: String) -> PlayerViewModel {
            PlayerViewModel(client: client, userID: "user-1", itemID: itemID, engine: FakePlaybackEngine())
        }
        let host = TVPlayerHostController(viewModel: viewModel("episode-s2e1"))
        var remembered: [String: String] = [:]
        host.rememberVersion = { mediaSourceID, itemID in remembered[itemID] = mediaSourceID }
        host.makeViewModel = { itemID, _, _ in viewModel(itemID) }
        let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok")
        func episode(_ id: String) -> MediaItem { MediaItem(dto: BaseItemDto(id: id, name: id, type: .episode), images: images) }

        host.advance(to: episode("episode-s2e2"), mediaSourceID: "episode-s2e2-1080p")
        host.advance(to: episode("episode-s2e3"), mediaSourceID: nil)

        XCTAssertEqual(remembered, ["episode-s2e2": "episode-s2e2-1080p"])
        host.close()
    }
}
