import Foundation
import Observation

/// A season download's version flow (#289), apart from `SeasonDownloadButton`
/// so it is tested with no network: scan every episode's sources, plan the
/// question (`BulkVersionPlanner`), wait for its answer, then enqueue.
///
/// Scanning first, rather than asking as each episode resolves, is what lets
/// a season whose episodes all have the same versions ask once: nothing can
/// be known about the season until every episode has answered. The scan's
/// sources are what is enqueued, so each episode costs one `/PlaybackInfo`,
/// as before #289.
///
/// Neither question marks "(Last Played)" and no answer is saved as the
/// playback preference: one label spans many episodes, and a download's
/// choice isn't a playback one (Benjamin, 2026-11-14).
///
/// Nothing here is season-specific but the name: it takes any list of items,
/// so a collection's download (#468) can drive it the same way.
@Observable @MainActor
final class SeasonDownloadCoordinator {
    enum Phase: Equatable {
        case idle
        /// Fetching every episode's sources.
        case scanning
        /// Every episode with versions has these, in this order: one question.
        case askingUniform([String])
        /// The episodes whose versions differ, each to be picked on its own
        /// (only those with two or more versions, in season order).
        case askingPerEpisode([EpisodeScan])
        /// Handing the episodes to `DownloadManager`.
        case queuing
    }

    private(set) var phase: Phase = .idle
    /// Episodes that couldn't be downloaded in the last run: a failed scan, a
    /// scan that listed no source, or a failed enqueue. Read once the phase
    /// is back to `.idle` for "N episodes couldn't be downloaded"; a
    /// cancelled run resets it, since nothing was attempted.
    private(set) var failureCount = 0

    private let fetchSources: @Sendable (String) async throws -> [MediaSourceInfo]
    private let enqueue: @Sendable (MediaItem, MediaSourceInfo, String?) async throws -> Void
    private let isStillMissing: @MainActor @Sendable (String) -> Bool
    /// The last run's successful scans, in the order given.
    private var scans: [EpisodeScan] = []
    /// Every episode the current run will queue, the single-version ones
    /// included: what the per-episode sheet's Download counts.
    var scannedEpisodeCount: Int { scans.count }
    private var limit = 1
    /// Which `start` the scan in flight belongs to.
    private var runID = 0

    /// `fetchSources` answers an item id with every source `/PlaybackInfo`
    /// lists; `enqueue` downloads one item's source, recording the version
    /// label (`nil` for an item with only one version). Audio and subtitles
    /// are `enqueue`'s to pick, as they were before versions.
    ///
    /// `isStillMissing` answers, just before each episode is enqueued,
    /// whether it still has nothing queued, downloading or downloaded. The
    /// episodes were chosen at the tap, and a scan and its question can take
    /// long enough for the user to download one by hand meanwhile; enqueuing
    /// it anyway would replace that download (`DownloadManager.enqueue`
    /// deletes any row first) with the season's version and default audio.
    init(
        fetchSources: @escaping @Sendable (String) async throws -> [MediaSourceInfo],
        enqueue: @escaping @Sendable (MediaItem, MediaSourceInfo, String?) async throws -> Void,
        isStillMissing: @escaping @MainActor @Sendable (String) -> Bool = { _ in true }
    ) {
        self.fetchSources = fetchSources
        self.enqueue = enqueue
        self.isStillMissing = isStillMissing
    }

    // Each entry point changes `phase` before it returns and does the rest in
    // the task it hands back. Synchronously, because a dialog's button runs
    // its action just before the dialog reports itself dismissed: the view
    // reads a dismissal while still `.askingUniform` as a cancel, so the
    // answer must already have moved the phase on.

    /// Scans `episodes`, at most `limit` at once (`maxConcurrentDownloads`:
    /// a large season shouldn't fire every request at the server together),
    /// then asks or, with nothing to ask, enqueues straight away.
    @discardableResult
    func start(episodes: [MediaItem], limit: Int) -> Task<Void, Never> {
        guard phase == .idle else { return Task {} }
        phase = .scanning
        failureCount = 0
        scans = []
        runID += 1
        let run = runID
        self.limit = max(1, limit)
        let fetch = fetchSources
        return Task {
            let results = await Self.bounded(episodes, limit: self.limit) { episode -> EpisodeScan? in
                guard let sources = try? await fetch(episode.id), !sources.isEmpty else { return nil }
                return EpisodeScan(episode: episode, sources: sources)
            }
            // Cancelled meanwhile (and perhaps started again): this scan's
            // answers belong to no question.
            guard phase == .scanning, runID == run else { return }
            scans = results.compactMap { $0 ?? nil }
            failureCount = results.count - scans.count
            switch BulkVersionPlanner.plan(scans) {
            case .noChoice:
                await queue(scans.map { ($0.episode, $0.sources[0], nil) })
            case .uniform(let labels):
                phase = .askingUniform(labels)
            case .perEpisode(let ids):
                let needingPick = Set(ids)
                phase = .askingPerEpisode(scans.filter { needingPick.contains($0.id) })
            }
        }
    }

    /// The one question's answer: each episode with versions downloads the
    /// one `label` names, and each with one version downloads that.
    @discardableResult
    func chooseUniform(_ label: String) -> Task<Void, Never> {
        guard case .askingUniform = phase else { return Task {} }
        phase = .queuing
        var jobs: [(MediaItem, MediaSourceInfo, String?)] = []
        for scan in scans {
            guard let source = BulkVersionPlanner.source(in: scan, forLabel: label) else {
                failureCount += 1
                continue
            }
            jobs.append((scan.episode, source, scan.versions.count > 1 ? label : nil))
        }
        return Task { await queue(jobs) }
    }

    /// The per-episode sheet's answer, `MediaVersion.id` by episode id. An
    /// episode missing from `picks` downloads its first version, the server's
    /// default, as the sheet starts on when nothing was remembered.
    @discardableResult
    func choosePerEpisode(_ picks: [String: String]) -> Task<Void, Never> {
        guard case .askingPerEpisode = phase else { return Task {} }
        phase = .queuing
        let jobs = scans.map { scan -> (MediaItem, MediaSourceInfo, String?) in
            let versions = scan.versions
            guard versions.count > 1 else { return (scan.episode, scan.sources[0], nil) }
            // By position: `versions(of:)` keeps the sources' order.
            let index = picks[scan.id].flatMap { pick in versions.firstIndex { $0.id == pick } } ?? 0
            return (scan.episode, scan.sources[index], versions[index].label)
        }
        return Task { await queue(jobs) }
    }

    /// Either question dismissed, or the button gone mid-scan (another season
    /// picked, the page closed): nothing downloads, and nothing is reported.
    /// A run already queuing is left to finish, since its episodes are being
    /// handed over one by one and stopping part-way would leave half a season.
    func cancel() {
        guard phase != .queuing else { return }
        phase = .idle
        scans = []
        failureCount = 0
    }

    private func queue(_ jobs: [(MediaItem, MediaSourceInfo, String?)]) async {
        phase = .queuing
        let enqueue = enqueue
        let isStillMissing = isStillMissing
        // Bounded like the scan: each enqueue makes its own requests (images,
        // trickplay, subtitles) before its row appears.
        let results = await Self.bounded(jobs, limit: limit) { job -> Bool in
            // Checked per job rather than once up front, since a bounded queue
            // of a large season takes a while to reach its last episodes.
            // Skipped isn't failed: the episode is being downloaded, just not
            // by this run.
            guard await isStillMissing(job.0.id) else { return true }
            do {
                try await enqueue(job.0, job.1, job.2)
                return true
            } catch {
                // Best-effort: one episode failing to enqueue shouldn't stop
                // the rest of the season from queuing.
                return false
            }
        }
        failureCount += results.filter { $0 != true }.count
        scans = []
        phase = .idle
    }

    /// `body` over `items`, at most `limit` at a time, answers in `items`'
    /// order.
    private nonisolated static func bounded<Item: Sendable, Result: Sendable>(
        _ items: [Item], limit: Int, _ body: @escaping @Sendable (Item) async -> Result
    ) async -> [Result?] {
        var results = [Result?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Result).self) { group in
            var nextIndex = 0
            func addNext() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                let item = items[index]
                nextIndex += 1
                group.addTask { (index, await body(item)) }
            }
            for _ in 0..<min(max(1, limit), items.count) { addNext() }
            for await (index, result) in group {
                results[index] = result
                addNext()
            }
        }
        return results
    }
}
