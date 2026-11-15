import XCTest
@testable import Dionysus

/// A season download's version flow (#289): scan every episode, then ask
/// once, per episode or not at all, and enqueue from the scan's own sources.
@MainActor
final class SeasonDownloadCoordinatorTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: nil)

    private func episode(_ id: String) -> MediaItem {
        MediaItem(dto: BaseItemDto(id: id, name: id, type: .episode), images: images)
    }

    private static func source(_ id: String, width: Int, hdr: Bool = false) -> MediaSourceInfo {
        var video = MediaStream(index: 0, type: "Video", codec: "hevc", width: width, height: width * 9 / 16)
        video.videoRangeType = hdr ? "HDR10" : "SDR"
        return MediaSourceInfo(id: id, mediaStreams: [video])
    }

    private static func twoResolutions(_ id: String) -> [MediaSourceInfo] {
        [source("\(id)-4k", width: 3840, hdr: true), source("\(id)-1080p", width: 1920)]
    }

    /// What the coordinator asked the server for and handed the manager.
    private actor Recorder {
        var fetched: [String] = []
        var enqueued: [Enqueued] = []
        var inFlight = 0
        var maxInFlight = 0

        struct Enqueued: Equatable {
            let itemID: String
            let sourceID: String?
            let label: String?
        }

        func fetchStarted(_ id: String) {
            fetched.append(id)
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }

        func fetchEnded() { inFlight -= 1 }

        func record(_ entry: Enqueued) { enqueued.append(entry) }
    }

    private struct ScanFailed: Error {}

    /// A coordinator whose server answers `sources[id]`, or fails for an id
    /// in `failing`.
    private func makeCoordinator(
        _ recorder: Recorder,
        sources: [String: [MediaSourceInfo]],
        failing: Set<String> = [],
        fetchDelay: Duration = .zero,
        isStillMissing: @escaping @MainActor @Sendable (String) -> Bool = { _ in true }
    ) -> SeasonDownloadCoordinator {
        SeasonDownloadCoordinator(
            fetchSources: { id in
                await recorder.fetchStarted(id)
                if fetchDelay > .zero { try? await Task.sleep(for: fetchDelay) }
                await recorder.fetchEnded()
                if failing.contains(id) { throw ScanFailed() }
                return sources[id] ?? []
            },
            enqueue: { item, source, label in
                await recorder.record(.init(itemID: item.id, sourceID: source.id, label: label))
            },
            isStillMissing: isStillMissing
        )
    }

    func test_coordinator_uniform_enqueuesChosenLabelForEach() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder, sources: [
            "e1": Self.twoResolutions("e1"), "e2": [Self.source("e2-only", width: 1920)], "e3": Self.twoResolutions("e3"),
        ])

        await coordinator.start(episodes: [episode("e1"), episode("e2"), episode("e3")], limit: 2).value
        XCTAssertEqual(coordinator.phase, .askingUniform(["4K HDR10", "1080p"]))
        let nothingYet = await recorder.enqueued
        XCTAssertTrue(nothingYet.isEmpty, "Nothing is queued while the question is up")

        await coordinator.chooseUniform("1080p").value

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.failureCount, 0)
        let enqueued = await recorder.enqueued
        XCTAssertEqual(Set(enqueued.map(\.itemID)), ["e1", "e2", "e3"])
        XCTAssertEqual(enqueued.first { $0.itemID == "e1" }, .init(itemID: "e1", sourceID: "e1-1080p", label: "1080p"))
        XCTAssertEqual(enqueued.first { $0.itemID == "e3" }, .init(itemID: "e3", sourceID: "e3-1080p", label: "1080p"))
        // A single-version episode downloads its only file, with no label.
        XCTAssertEqual(enqueued.first { $0.itemID == "e2" }, .init(itemID: "e2", sourceID: "e2-only", label: nil))
        // The scan's sources are reused: one `/PlaybackInfo` per episode.
        let fetched = await recorder.fetched
        XCTAssertEqual(fetched.sorted(), ["e1", "e2", "e3"])
    }

    func test_coordinator_perEpisode_enqueuesEachPick() async {
        let recorder = Recorder()
        let edition = [Self.source("e2-original", width: 1920), Self.source("e2-extended", width: 1280)]
        let coordinator = makeCoordinator(recorder, sources: [
            "e1": Self.twoResolutions("e1"), "e2": edition, "e3": [Self.source("e3-only", width: 1920)],
        ])

        await coordinator.start(episodes: [episode("e1"), episode("e2"), episode("e3")], limit: 3).value
        guard case .askingPerEpisode(let scans) = coordinator.phase else {
            return XCTFail("expected the per-episode question, got \(coordinator.phase)")
        }
        XCTAssertEqual(scans.map(\.episode.id), ["e1", "e2"], "Only episodes with a choice are listed, in order")

        await coordinator.choosePerEpisode(["e1": "e1-4k", "e2": "e2-extended"]).value

        XCTAssertEqual(coordinator.phase, .idle)
        let enqueued = await recorder.enqueued
        XCTAssertEqual(enqueued.first { $0.itemID == "e1" }, .init(itemID: "e1", sourceID: "e1-4k", label: "4K HDR10"))
        XCTAssertEqual(enqueued.first { $0.itemID == "e2" }, .init(itemID: "e2", sourceID: "e2-extended", label: "720p"))
        XCTAssertEqual(enqueued.first { $0.itemID == "e3" }, .init(itemID: "e3", sourceID: "e3-only", label: nil))
    }

    func test_coordinator_noChoice_enqueuesWithoutAsking() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder, sources: [
            "e1": [Self.source("e1-only", width: 1920)], "e2": [Self.source("e2-only", width: 1920)],
        ])

        await coordinator.start(episodes: [episode("e1"), episode("e2")], limit: 1).value

        XCTAssertEqual(coordinator.phase, .idle)
        let enqueued = await recorder.enqueued
        XCTAssertEqual(
            enqueued.sorted { $0.itemID < $1.itemID },
            [.init(itemID: "e1", sourceID: "e1-only", label: nil), .init(itemID: "e2", sourceID: "e2-only", label: nil)]
        )
    }

    /// A failed `/PlaybackInfo` (or one listing no source) counts towards
    /// "N episodes couldn't be downloaded"; the rest still queue.
    func test_coordinator_scanFailure_countsAndContinues() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(
            recorder,
            sources: ["e1": [Self.source("e1-only", width: 1920)], "e3": [Self.source("e3-only", width: 1920)]],
            failing: ["e2"]
        )

        await coordinator.start(episodes: [episode("e1"), episode("e2"), episode("e3"), episode("e4")], limit: 2).value

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.failureCount, 2, "e2 failed and e4 listed no source")
        let enqueued = await recorder.enqueued
        XCTAssertEqual(Set(enqueued.map(\.itemID)), ["e1", "e3"])
    }

    func test_coordinator_cancel_enqueuesNothing_returnsIdle() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder, sources: ["e1": Self.twoResolutions("e1"), "e2": Self.twoResolutions("e2")])

        await coordinator.start(episodes: [episode("e1"), episode("e2")], limit: 2).value
        XCTAssertEqual(coordinator.phase, .askingUniform(["4K HDR10", "1080p"]))
        coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.failureCount, 0)

        // A late answer after the cancel queues nothing either.
        await coordinator.chooseUniform("1080p").value
        let enqueued = await recorder.enqueued
        XCTAssertTrue(enqueued.isEmpty)

        // The per-episode question cancels the same way.
        let mixed = makeCoordinator(recorder, sources: [
            "e1": Self.twoResolutions("e1"),
            "e2": [Self.source("e2-a", width: 1280), Self.source("e2-b", width: 1920)],
        ])
        await mixed.start(episodes: [episode("e1"), episode("e2")], limit: 2).value
        guard case .askingPerEpisode = mixed.phase else { return XCTFail("expected the per-episode question") }
        mixed.cancel()
        XCTAssertEqual(mixed.phase, .idle)
        await mixed.choosePerEpisode(["e1": "e1-4k"]).value
        let stillNothing = await recorder.enqueued
        XCTAssertTrue(stillNothing.isEmpty)
    }

    func test_coordinator_respectsConcurrencyLimit() async {
        let recorder = Recorder()
        let ids = (1...6).map { "e\($0)" }
        let coordinator = makeCoordinator(
            recorder,
            sources: Dictionary(uniqueKeysWithValues: ids.map { ($0, [Self.source("\($0)-only", width: 1920)]) }),
            fetchDelay: .milliseconds(20)
        )

        await coordinator.start(episodes: ids.map(episode), limit: 2).value

        let maxInFlight = await recorder.maxInFlight
        XCTAssertEqual(maxInFlight, 2, "At most `limit` scans at once, and the limit is actually used")
        let enqueued = await recorder.enqueued
        XCTAssertEqual(enqueued.count, 6)
    }

    /// The season button goes away mid-scan (another season picked, the page
    /// closed): the scan's answers are dropped, and nothing is asked or queued.
    func test_coordinator_cancelDuringScan_queuesNothing_returnsIdle() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(
            recorder,
            sources: ["e1": [Self.source("e1-only", width: 1920)], "e2": [Self.source("e2-only", width: 1920)]],
            fetchDelay: .milliseconds(50)
        )

        let run = coordinator.start(episodes: [episode("e1"), episode("e2")], limit: 2)
        XCTAssertEqual(coordinator.phase, .scanning)
        coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .idle)
        await run.value

        XCTAssertEqual(coordinator.phase, .idle, "A cancelled scan doesn't go on to ask or queue")
        XCTAssertEqual(coordinator.failureCount, 0)
        let enqueued = await recorder.enqueued
        XCTAssertTrue(enqueued.isEmpty, "A cancelled scan queues nothing, even with no question to ask")
    }

    /// One run at a time: a second start while the first scans, or while its
    /// question waits, is ignored.
    func test_coordinator_start_refusedWhileRunInProgress() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(
            recorder,
            sources: ["e1": Self.twoResolutions("e1"), "e2": Self.twoResolutions("e2")],
            fetchDelay: .milliseconds(30)
        )

        let first = coordinator.start(episodes: [episode("e1")], limit: 1)
        await coordinator.start(episodes: [episode("e2")], limit: 1).value
        XCTAssertEqual(coordinator.phase, .scanning, "The second start returns at once and changes nothing")
        await first.value
        XCTAssertEqual(coordinator.phase, .askingUniform(["4K HDR10", "1080p"]))
        await coordinator.start(episodes: [episode("e2")], limit: 1).value
        XCTAssertEqual(coordinator.phase, .askingUniform(["4K HDR10", "1080p"]), "Nor while a question waits")
        let fetched = await recorder.fetched
        XCTAssertEqual(fetched, ["e1"], "Only the first run scanned")

        await coordinator.chooseUniform("1080p").value
        let enqueued = await recorder.enqueued
        XCTAssertEqual(enqueued.map(\.itemID), ["e1"])
    }

    /// Episodes downloaded by hand while the season scanned or asked.
    @MainActor private final class HandDownloads {
        var itemIDs: Set<String> = []
    }

    /// An episode downloaded by hand while the season scanned (or waited on
    /// its question) keeps that download: the season skips it rather than
    /// replacing it with its own version and default audio, and it isn't a
    /// failure.
    func test_coordinator_episodeDownloadedDuringScan_isSkipped_notAFailure() async {
        let recorder = Recorder()
        let byHand = HandDownloads()
        let coordinator = makeCoordinator(
            recorder,
            sources: ["e1": Self.twoResolutions("e1"), "e2": Self.twoResolutions("e2"), "e3": Self.twoResolutions("e3")],
            isStillMissing: { !byHand.itemIDs.contains($0) }
        )

        await coordinator.start(episodes: [episode("e1"), episode("e2"), episode("e3")], limit: 2).value
        XCTAssertEqual(coordinator.phase, .askingUniform(["4K HDR10", "1080p"]))
        byHand.itemIDs.insert("e2")
        await coordinator.chooseUniform("1080p").value

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.failureCount, 0, "A skipped episode isn't a failure")
        let enqueued = await recorder.enqueued
        XCTAssertEqual(Set(enqueued.map(\.itemID)), ["e1", "e3"])
    }
}
