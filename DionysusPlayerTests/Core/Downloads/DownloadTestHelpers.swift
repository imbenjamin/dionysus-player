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
        trickplayInfo: TrickplayInfo? = nil
    ) -> DownloadedItem {
        DownloadedItem(
            itemID: itemID,
            userID: "user-1",
            mediaSourceID: "src-1",
            kind: .movie,
            title: "Test Movie \(itemID)",
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
            trickplayInfo: trickplayInfo
        )
    }
}
