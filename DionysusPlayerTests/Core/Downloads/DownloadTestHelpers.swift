import Foundation
import SwiftData
@testable import Dionysus

/// Shared test fixtures for the offline-downloads model layer.
enum DownloadTestHelpers {
    @MainActor
    static func makeInMemoryStore() -> DownloadStore {
        let schema = Schema([DownloadedItem.self])
        // swiftlint:disable:next force_try — an in-memory container has
        // nothing external to fail on.
        let container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return DownloadStore(modelContainer: container)
    }

    static func makeMetadata() -> DownloadedItemMetadata {
        DownloadedItemMetadata(
            overview: nil, taglines: [], genres: [], studios: [],
            productionYear: nil, premiereDate: nil, communityRating: nil, officialRating: nil, people: []
        )
    }

    static func makeItem(
        itemID: String,
        pendingSync: Bool = false,
        markedForDeletion: Bool = false,
        posterImagePath: String? = nil,
        backdropImagePath: String? = nil,
        logoImagePath: String? = nil,
        thumbImagePath: String? = nil,
        status: DownloadStatus = .queued,
        pendingDownloadURLString: String? = nil,
        createdAt: Date = Date(),
        trickplayInfo: TrickplayInfo? = nil,
        userID: String = "user-1",
        kind: DownloadedItemKind = .movie,
        seriesID: String? = nil,
        seasonID: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        episodeNumberEnd: Int? = nil,
        hasNextEpisodeRecord: Bool = false,
        nextEpisodeSeasonNumber: Int? = nil,
        nextEpisodeNumber: Int? = nil
    ) -> DownloadedItem {
        DownloadedItem(
            itemID: itemID,
            userID: userID,
            mediaSourceID: "src-1",
            kind: kind,
            title: "Test Movie \(itemID)",
            seriesID: seriesID,
            seasonID: seasonID,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            requestedResolution: .hd1080p,
            requestedPreset: .normal,
            videoFilePath: DownloadFileStore.videoRelativePath(itemID: itemID),
            status: status,
            pendingDownloadURLString: pendingDownloadURLString,
            createdAt: createdAt,
            pendingSync: pendingSync,
            markedForDeletion: markedForDeletion,
            metadata: makeMetadata(),
            posterImagePath: posterImagePath,
            backdropImagePath: backdropImagePath,
            logoImagePath: logoImagePath,
            thumbImagePath: thumbImagePath,
            trickplayInfo: trickplayInfo,
            episodeNumberEnd: episodeNumberEnd,
            hasNextEpisodeRecord: hasNextEpisodeRecord,
            nextEpisodeSeasonNumber: nextEpisodeSeasonNumber,
            nextEpisodeNumber: nextEpisodeNumber
        )
    }
}
