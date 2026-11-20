import XCTest
@testable import Dionysus

/// `DownloadedNextEpisode.find(after:among:)`: offline Up Next (#274) cues only
/// the immediate next episode, and only when it's downloaded. A gap gets no
/// Up Next (Benjamin, 2026-11-20); a season break needs the server's answer,
/// recorded at download time.
@MainActor
final class DownloadedNextEpisodeTests: XCTestCase {
    private func episode(
        _ season: Int?, _ episode: Int?, end: Int? = nil,
        seriesID: String = "series-1", userID: String = "user-1",
        status: DownloadStatus = .completed, markedForDeletion: Bool = false,
        record: (season: Int?, episode: Int?)? = nil
    ) -> DownloadedItem {
        DownloadTestHelpers.makeItem(
            itemID: "\(seriesID)-\(userID)-s\(season ?? -1)e\(episode ?? -1)",
            markedForDeletion: markedForDeletion,
            status: status,
            userID: userID,
            kind: .episode,
            seriesID: seriesID,
            seasonID: season.map { "season-\($0)" },
            seasonNumber: season,
            episodeNumber: episode,
            episodeNumberEnd: end,
            hasNextEpisodeRecord: record != nil,
            nextEpisodeSeasonNumber: record?.season,
            nextEpisodeNumber: record?.episode
        )
    }

    func test_sameSeason_nextNumber_isFound() {
        let current = episode(1, 1)
        let next = episode(1, 2)
        XCTAssertEqual(DownloadedNextEpisode.find(after: current, among: [current, next])?.itemID, next.itemID)
    }

    func test_gap_findsNothing() {
        let current = episode(1, 1)
        XCTAssertNil(DownloadedNextEpisode.find(after: current, among: [current, episode(1, 3)]))
    }

    func test_doubleEpisode_continuesAfterItsLastNumber() {
        let current = episode(1, 1, end: 2)
        let next = episode(1, 3)
        XCTAssertEqual(DownloadedNextEpisode.find(after: current, among: [current, next])?.itemID, next.itemID)
    }

    func test_seasonFinale_withRecord_findsNextSeason() {
        let current = episode(1, 3, record: (2, 1))
        let next = episode(2, 1)
        XCTAssertEqual(DownloadedNextEpisode.find(after: current, among: [current, next])?.itemID, next.itemID)
    }

    func test_seasonFinale_withoutRecord_findsNothing() {
        let current = episode(1, 3)
        XCTAssertNil(DownloadedNextEpisode.find(after: current, among: [current, episode(2, 1)]))
    }

    func test_recordSkippingASeason_findsNothingWhenThatSeasonIsMissing() {
        let current = episode(1, 3, record: (2, 1))
        XCTAssertNil(DownloadedNextEpisode.find(after: current, among: [current, episode(3, 1)]))
    }

    func test_seriesFinale_record_findsNothingAcrossASeasonBreak() {
        let current = episode(2, 2, record: (nil, nil))
        XCTAssertNil(DownloadedNextEpisode.find(after: current, among: [current, episode(3, 1)]))
    }

    /// The record is the server at download time. On a show still airing, S1E3
    /// was the last episode then; S1E4, downloaded since, is still the next.
    func test_staleSeriesEndRecord_stillCuesSameSeasonNext() {
        let current = episode(1, 3, record: (nil, nil))
        let next = episode(1, 4)
        XCTAssertEqual(DownloadedNextEpisode.find(after: current, among: [current, next])?.itemID, next.itemID)
    }

    /// S1E5 downloaded past a missing S1E4: the season goes on, so a stale
    /// "next is S2E1" record mustn't skip the gap.
    func test_staleNextSeasonRecord_withALaterSameSeasonDownload_findsNothing() {
        let current = episode(1, 3, record: (2, 1))
        XCTAssertNil(DownloadedNextEpisode.find(after: current, among: [current, episode(1, 5), episode(2, 1)]))
    }

    func test_staleNextSeasonRecord_prefersSameSeasonNext() {
        let current = episode(1, 3, record: (2, 1))
        let next = episode(1, 4)
        XCTAssertEqual(
            DownloadedNextEpisode.find(after: current, among: [current, next, episode(2, 1)])?.itemID, next.itemID
        )
    }

    func test_special_neverCues_andIsNeverCued() {
        let special = episode(0, 1)
        XCTAssertNil(DownloadedNextEpisode.find(after: special, among: [special, episode(0, 2)]), "A special cues nothing")
        let current = episode(1, 3, record: (0, 1))
        XCTAssertNil(DownloadedNextEpisode.find(after: current, among: [current, special]), "A special is never cued")
    }

    func test_unnumbered_findsNothing() {
        let current = episode(1, nil)
        XCTAssertNil(DownloadedNextEpisode.find(after: current, among: [current, episode(1, 1)]))
    }

    func test_incompleteOrMarkedForDeletionNext_isSkipped() {
        let current = episode(1, 1)
        for next in [episode(1, 2, status: .downloading), episode(1, 2, status: .failed), episode(1, 2, markedForDeletion: true)] {
            XCTAssertNil(DownloadedNextEpisode.find(after: current, among: [current, next]))
        }
    }

    func test_otherUsersDownload_isNotCued() {
        let current = episode(1, 1)
        XCTAssertNil(DownloadedNextEpisode.find(after: current, among: [current, episode(1, 2, userID: "user-2")]))
    }

    func test_otherSeries_isNotCued() {
        let current = episode(1, 1)
        XCTAssertNil(DownloadedNextEpisode.find(after: current, among: [current, episode(1, 2, seriesID: "series-2")]))
    }
}
