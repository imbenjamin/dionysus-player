import Foundation

/// Works out whether starting an item plays a known version or asks which
/// (`MediaVersionChoice`), over what the pure rule can't hold: the item's
/// sources, fetched when the caller has none, and the pick remembered for this
/// user. Shared by every play entry point on both apps
/// (`AssetDetailViewModel.playbackDecision(for:isResume:)`, and the Apple TV's
/// Home hero, which has no detail view model), so they all ask alike.
///
/// Every failure falls back to `.play(mediaSourceID: nil)`, the server's
/// default: being unable to list the versions must never stop playback.
@MainActor
struct MediaVersionResolver {
    let client: JellyfinAPIClient
    let userID: String
    let preferences: MediaVersionPreferenceStore

    /// A user-started play; `isResume` is whether the item has a resume
    /// point (`MediaItem.canResume`), whichever button was tapped. An item
    /// from a listing (a season's episodes, a
    /// collection's or playlist's members, NextUp's pick) comes without
    /// `MediaSources`, so it's fetched first; one from a detail page already
    /// has them and costs no request.
    func decision(for item: MediaItem, isResume: Bool) async -> MediaVersionChoice {
        guard let sources = await sources(of: item) else { return .play(mediaSourceID: nil) }
        return MediaVersionChoice.decide(
            versions: MediaVersion.versions(of: sources),
            isResume: isResume,
            preferredSourceID: preferences.preferredMediaSourceID(forItem: item.id, userID: userID)
        )
    }

    /// The next item of a session already under way, when the player had no
    /// answer to hand over (its fetch of the next item's sources hadn't landed,
    /// or failed): decided afresh, continuing the version labelled as the one
    /// just played (`MediaVersionChoice.continuation`).
    func continuation(forItemID itemID: String, previousVersionLabel: String?) async -> MediaVersionChoice {
        guard let dto = try? await client.item(userID: userID, itemID: itemID, fields: "MediaSources") else {
            return .play(mediaSourceID: nil)
        }
        return MediaVersionChoice.continuation(
            versions: MediaVersion.versions(of: dto.mediaSources ?? []),
            preferredSourceID: preferences.preferredMediaSourceID(forItem: itemID, userID: userID),
            previousLabel: previousVersionLabel
        )
    }

    /// The item's own sources, else fetched with `detailFields`; `nil` when
    /// that fetch fails.
    private func sources(of item: MediaItem) async -> [MediaSourceInfo]? {
        if let sources = item.dto.mediaSources { return sources }
        guard let dto = try? await client.item(userID: userID, itemID: item.id) else { return nil }
        return dto.mediaSources ?? []
    }
}
