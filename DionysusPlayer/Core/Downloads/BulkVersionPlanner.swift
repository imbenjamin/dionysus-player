import Foundation

/// One item of a bulk download with every source `/PlaybackInfo` listed for
/// it: what the version question is planned from, and what is enqueued
/// afterwards, so no item is fetched twice. Named for a season's episodes,
/// but nothing here is season-specific: a collection's titles (#468) scan
/// the same way.
struct EpisodeScan: Identifiable, Equatable {
    let episode: MediaItem
    let sources: [MediaSourceInfo]

    var id: String { episode.id }

    /// Empty for a single-version item, which has nothing to ask about.
    var versions: [MediaVersion] { MediaVersion.versions(of: sources) }
}

/// What a bulk download asks about versions (#289).
enum BulkVersionPlan: Equatable {
    /// No item has more than one version: download as before, asking nothing.
    case noChoice
    /// Every item with versions has the same ones, in the same order: ask
    /// once, listing `labels`, and apply the answer to each.
    case uniform(labels: [String])
    /// The items' versions differ: ask per item. The ids of the items that
    /// need a pick, in the order they were scanned (a season's order).
    case perEpisode([String])
}

/// Decides how a bulk download asks which version, apart from the view so the
/// rule is tested on its own. Pure and generic over items, so a collection's
/// download (#468) can reuse it as a season's does.
enum BulkVersionPlanner {
    /// Only items with two or more versions count (D6): a single-version item
    /// downloads its one file whatever is chosen, so it neither breaks a
    /// season that is otherwise uniform nor gets a row of its own to pick in.
    ///
    /// "The same versions" is the same **ordered** label list. Labels, not
    /// ids, because every episode's sources have ids of their own while "4K
    /// HDR10" means the same thing across them. Ordered, because the first is
    /// the server's default for each item: two items listing the same labels
    /// the other way round don't agree on which is the main file, and one
    /// question would hide that.
    static func plan(_ scans: [EpisodeScan]) -> BulkVersionPlan {
        let choosing = scans.filter { $0.versions.count > 1 }
        guard let first = choosing.first else { return .noChoice }
        let labels = first.versions.map(\.label)
        if choosing.allSatisfy({ $0.versions.map(\.label) == labels }) {
            return .uniform(labels: labels)
        }
        return .perEpisode(choosing.map(\.episode.id))
    }

    /// The source of `scan` that `label` names, as `MediaVersion.versions(of:)`
    /// labels it (duplicates included: "1080p (2)" is the second 1080p file of
    /// *each* item). A single-version item returns its only source, whatever
    /// the label, and `nil` means nothing to download.
    ///
    /// Matched by position, not by `MediaVersion.id`: `versions(of:)` keeps
    /// the sources' order, and a source with no id gets a made-up one there.
    static func source(in scan: EpisodeScan, forLabel label: String) -> MediaSourceInfo? {
        let versions = scan.versions
        guard versions.count > 1 else { return scan.sources.first }
        guard let index = versions.firstIndex(where: { $0.label == label }) else { return nil }
        return scan.sources[index]
    }
}
