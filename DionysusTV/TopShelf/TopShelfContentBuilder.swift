import Foundation

/// One Top Shelf carousel item, platform-free so it's testable; the extension
/// turns it into a `TVTopShelfCarouselItem`.
struct TopShelfEntry: Equatable {
    enum Context: Equatable { case continueWatching, nextUp, recentlyAdded }
    enum MediaOption: Equatable, Hashable { case hd, uhd4K, hdr, dolbyVision, atmos, closedCaptions }

    var id: String
    var title: String
    var contextTitle: String
    var summary: String?
    var genre: String?
    var duration: TimeInterval?
    var releaseYear: Int?
    var cast: [String]
    var mediaOptions: Set<MediaOption>
    var image1x: URL
    var image2x: URL
    var displayURL: URL
    var playURL: URL
    /// The title's logo (an episode's show's), drawn into the art because
    /// tvOS 27 draws no text over a third-party carousel.
    var logoURL: URL?
    /// "1h 45m remaining", for Continue Watching only (Benjamin, 2026-10-14).
    var remainingText: String?
    /// Names the composited art: changes with anything drawn into it.
    var artworkKey: String
}

/// The shelf's content (Benjamin, 2026-10-14): the first 3 Continue Watching
/// items, then Next Up not already shown, then Recently Added, 10 at most.
/// An item is shown once, a show once (its resumed episode wins over its Next
/// Up), and a title with no backdrop up its chain is left out: a carousel
/// item without art draws an empty frame.
enum TopShelfContentBuilder {
    static let continueWatchingLimit = 3
    static let totalLimit = 10

    static func entries(
        resume: [BaseItemDto], nextUp: [BaseItemDto], latest: [BaseItemDto],
        images: ImageURLBuilder, serverID: String
    ) -> [TopShelfEntry] {
        var entries: [TopShelfEntry] = []
        var seenItems = Set<String>()
        var seenShows = Set<String>()

        func take(_ dtos: [BaseItemDto], as context: TopShelfEntry.Context, limit: Int) {
            var taken = 0
            for dto in dtos where taken < limit && entries.count < totalLimit {
                guard dto.type != .season, !(context == .continueWatching && dto.type == .series) else { continue }
                guard !seenItems.contains(dto.id) else { continue }
                // An episode's show, or the show itself: Latest groups a TV
                // library's new episodes into the show.
                let show = dto.type == .series ? dto.id : dto.seriesId
                if let show, seenShows.contains(show) { continue }
                guard let entry = entry(for: MediaItem(dto: dto, images: images), context: context, images: images, serverID: serverID) else { continue }
                entries.append(entry)
                seenItems.insert(dto.id)
                if let show { seenShows.insert(show) }
                taken += 1
            }
        }

        take(resume, as: .continueWatching, limit: continueWatchingLimit)
        take(nextUp, as: .nextUp, limit: totalLimit)
        take(latest, as: .recentlyAdded, limit: totalLimit)
        return entries
    }

    private static func entry(
        for item: MediaItem, context: TopShelfEntry.Context, images: ImageURLBuilder, serverID: String
    ) -> TopShelfEntry? {
        guard let art = backdrop(of: item),
              let image1x = images.url(itemID: art.itemID, imageType: "Backdrop", tag: art.tag, maxWidth: 1920),
              let image2x = images.url(itemID: art.itemID, imageType: "Backdrop", tag: art.tag, maxWidth: 3840)
        else { return nil }
        let logo = logo(of: item)
        let remainingMinutes = context == .continueWatching ? remainingMinutes(of: item.dto) : nil
        let contextLabel = switch context {
        case .continueWatching: String(localized: "Continue Watching")
        case .nextUp: String(localized: "Next Up")
        case .recentlyAdded: String(localized: "Recently Added")
        }
        let contextTitle = item.kind == .episode
            ? [contextLabel, item.numberedEpisodeName].joined(separator: " \u{00B7} ")
            : contextLabel
        return TopShelfEntry(
            id: item.id,
            title: item.railTitle,
            contextTitle: contextTitle,
            summary: item.overview,
            genre: item.genres.first,
            duration: item.dto.runTimeTicks.map { TimeInterval($0) / 10_000_000 },
            releaseYear: item.dto.productionYear,
            cast: item.cast.prefix(4).map(\.name),
            mediaOptions: mediaOptions(item.metadataBadges),
            image1x: image1x,
            image2x: image2x,
            displayURL: TVDeepLink(action: .item, itemID: item.id, serverID: serverID).url,
            playURL: TVDeepLink(action: .play, itemID: item.id, serverID: serverID).url,
            logoURL: logo.flatMap { images.url(itemID: $0.itemID, imageType: "Logo", tag: $0.tag, maxWidth: 800) },
            remainingText: remainingMinutes.map { String(localized: "\(durationText(minutes: $0)) remaining") },
            artworkKey: artworkKey(
                itemID: item.id, backdropTag: art.tag, logoTag: logo?.tag, context: context, remainingMinutes: remainingMinutes
            )
        )
    }

    /// The item's logo, else the nearest ancestor's (`MediaItem.logoImageURL`).
    private static func logo(of item: MediaItem) -> (itemID: String, tag: String)? {
        if let tag = item.dto.imageTags?["Logo"] { return (item.id, tag) }
        if let parent = item.dto.parentLogoItemId, let tag = item.dto.parentLogoImageTag { return (parent, tag) }
        return nil
    }

    /// Minutes left, rounded up so the last seconds still say 1m; `nil`
    /// without a runtime or a position.
    private static func remainingMinutes(of dto: BaseItemDto) -> Int? {
        guard let runtime = dto.runTimeTicks, runtime > 0,
              let position = dto.userData?.playbackPositionTicks, position > 0
        else { return nil }
        let seconds = Double(max(runtime - position, 0)) / 10_000_000
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    /// Home's runtime form (`MediaItem.durationText`): "1h 45m", "45m".
    private static func durationText(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Bumped when the drawing changes, so cached art is redrawn.
    private static let artworkVersion = 6

    /// A file name: the remaining time is drawn to the minute, so a few
    /// seconds more watched reuses the same art.
    static func artworkKey(
        itemID: String, backdropTag: String, logoTag: String?, context: TopShelfEntry.Context, remainingMinutes: Int?
    ) -> String {
        let remaining = remainingMinutes.map(String.init) ?? "none"
        let parts = ["v\(artworkVersion)", itemID, backdropTag, logoTag ?? "nologo", "\(context)", remaining]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(parts.joined(separator: "_").unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    /// Jellyfin's own fallback: the item's backdrop, else the nearest
    /// ancestor's it names (an episode's show).
    private static func backdrop(of item: MediaItem) -> (itemID: String, tag: String)? {
        if let tag = item.dto.backdropImageTags?.first { return (item.id, tag) }
        if let parent = item.dto.parentBackdropItemId, let tag = item.dto.parentBackdropImageTags?.first { return (parent, tag) }
        return nil
    }

    private static func mediaOptions(_ badges: [String]) -> Set<TopShelfEntry.MediaOption> {
        var options = Set<TopShelfEntry.MediaOption>()
        for badge in badges {
            switch badge {
            case "4K": options.insert(.uhd4K)
            case "HD": options.insert(.hd)
            case "Dolby Vision": options.insert(.dolbyVision)
            case "HDR10", "HDR10+", "HDR": options.insert(.hdr)
            case "Dolby Atmos": options.insert(.atmos)
            case "CC": options.insert(.closedCaptions)
            default: break
            }
        }
        return options
    }
}
