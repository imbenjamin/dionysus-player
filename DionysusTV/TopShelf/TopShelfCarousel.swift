import Foundation
import TVServices

/// What the Top Shelf extension hands tvOS (M6), in the app target as well so
/// it's unit-tested (TQ-25): `ContentProvider` only carries the reply.
enum TopShelfCarousel {
    /// The whole load: the mirrored session's rows, their composited art, and
    /// the carousel. `nil` (the static Top Shelf image) when there is nothing
    /// to show: no session, a revoked token, a silent server.
    static func content(session: TopShelfSession?, urlSession: URLSession, store: TopShelfArtworkStore?) async -> (any TVTopShelfContent)? {
        let entries = await TopShelfLoader.load(session: session, urlSession: urlSession)
        let art = await TopShelfArtworkComposer.artwork(for: entries, store: store, session: urlSession)
        return content(entries, art: art)
    }

    /// `.actions`: tvOS 27 draws no text over either style, so the title is
    /// in the art, and Play and More Info are our two links.
    static func content(_ entries: [TopShelfEntry], art: [String: URL]) -> TVTopShelfCarouselContent? {
        guard !entries.isEmpty else { return nil }
        return TVTopShelfCarouselContent(style: .actions, items: entries.map { item($0, art: art[$0.id]) })
    }

    static func item(_ entry: TopShelfEntry, art: URL?) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: entry.id)
        item.title = entry.title
        item.contextTitle = entry.contextTitle
        item.summary = entry.summary
        item.genre = entry.genre
        if let duration = entry.duration { item.duration = duration }
        if let year = entry.releaseYear {
            item.creationDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: year))
        }
        if !entry.cast.isEmpty {
            item.namedAttributes = [TVTopShelfNamedAttribute(name: String(localized: "Starring"), values: entry.cast)]
        }
        item.mediaOptions = mediaOptions(entry.mediaOptions)
        // 2x only: the scale Apple TV renders (Sodalite: setting both doubles
        // the system's fetches). Art not drawn (no App Group, a backdrop that
        // failed, out of time) leaves the plain backdrop.
        item.setImageURL(art ?? entry.image2x, for: .screenScale2x)
        item.displayAction = TVTopShelfAction(url: entry.displayURL)
        item.playAction = TVTopShelfAction(url: entry.playURL)
        return item
    }

    /// One resolution and one colour space each, the better one winning.
    static func mediaOptions(_ options: Set<TopShelfEntry.MediaOption>) -> TVTopShelfCarouselItem.MediaOptions {
        var result: TVTopShelfCarouselItem.MediaOptions = []
        if options.contains(.uhd4K) { result.insert(.videoResolution4K) } else if options.contains(.hd) { result.insert(.videoResolutionHD) }
        if options.contains(.dolbyVision) { result.insert(.videoColorSpaceDolbyVision) } else if options.contains(.hdr) { result.insert(.videoColorSpaceHDR) }
        if options.contains(.atmos) { result.insert(.audioDolbyAtmos) }
        if options.contains(.closedCaptions) { result.insert(.audioTranscriptionClosedCaptioning) }
        return result
    }
}
