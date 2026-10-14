import TVServices

/// The Top Shelf (M6). tvOS calls this when the app's icon is in the top row
/// and on its own schedule; the app also asks for a refresh after playback,
/// sign-in or a watched change (`TopShelfRefresh`).
final class ContentProvider: TVTopShelfContentProvider {
    /// The completion-handler form: the `async` override doesn't compile
    /// under Swift 6 (its return isn't Sendable; spike).
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        let reply = Reply(completionHandler)
        // Only hands the reply on: Xcode 26.6's region-based isolation
        // checker gave up on a closure that did the work itself.
        Task.detached { await ContentProvider.respond(to: reply) }
    }

    private static func respond(to reply: Reply) async {
        let urlSession = TopShelfLoader.makeSession()
        let entries = await TopShelfLoader.load(session: TopShelfSessionMirror.read(), urlSession: urlSession)
        let art = await TopShelfArtworkComposer.artwork(for: entries, store: .shared(), session: urlSession)
        reply.send(content(entries, art: art))
    }

    /// `.actions`: tvOS 27 draws no text over either style, so the title is
    /// in the art, and Play and More Info are our two links.
    private static func content(_ entries: [TopShelfEntry], art: [String: URL]) -> (any TVTopShelfContent)? {
        guard !entries.isEmpty else { return nil }
        var items: [TVTopShelfCarouselItem] = []
        for entry in entries {
            items.append(item(entry, art: art[entry.id]))
        }
        return TVTopShelfCarouselContent(style: .actions, items: items)
    }

    /// The system's completion handler, carried into the fetch's task. It's
    /// called once, from that task; TV Services takes it from any thread.
    private final class Reply: @unchecked Sendable {
        private let handler: ((any TVTopShelfContent)?) -> Void
        init(_ handler: @escaping ((any TVTopShelfContent)?) -> Void) { self.handler = handler }
        func send(_ content: (any TVTopShelfContent)?) { handler(content) }
    }

    private static func item(_ entry: TopShelfEntry, art: URL?) -> TVTopShelfCarouselItem {
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
        // the system's fetches).
        item.setImageURL(art ?? entry.image2x, for: .screenScale2x)
        item.displayAction = TVTopShelfAction(url: entry.displayURL)
        item.playAction = TVTopShelfAction(url: entry.playURL)
        return item
    }

    private static func mediaOptions(_ options: Set<TopShelfEntry.MediaOption>) -> TVTopShelfCarouselItem.MediaOptions {
        var result: TVTopShelfCarouselItem.MediaOptions = []
        if options.contains(.uhd4K) { result.insert(.videoResolution4K) } else if options.contains(.hd) { result.insert(.videoResolutionHD) }
        if options.contains(.dolbyVision) { result.insert(.videoColorSpaceDolbyVision) } else if options.contains(.hdr) { result.insert(.videoColorSpaceHDR) }
        if options.contains(.atmos) { result.insert(.audioDolbyAtmos) }
        if options.contains(.closedCaptions) { result.insert(.audioTranscriptionClosedCaptioning) }
        return result
    }
}
