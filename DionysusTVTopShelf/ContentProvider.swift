import TVServices

/// The Top Shelf (M6). tvOS calls this when the app's icon is in the top row
/// and on its own schedule; the app also asks for a refresh after playback,
/// sign-in or a watched change (`TopShelfRefresh`). The work is
/// `TopShelfCarousel`'s, which the app's unit tests run.
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
        let content = await TopShelfCarousel.content(
            session: TopShelfSessionMirror.read(), urlSession: TopShelfLoader.makeSession(), store: .shared())
        reply.send(content)
    }

    /// The system's completion handler, carried into the fetch's task. It's
    /// called once, from that task; TV Services takes it from any thread.
    private final class Reply: @unchecked Sendable {
        private let handler: ((any TVTopShelfContent)?) -> Void
        init(_ handler: @escaping ((any TVTopShelfContent)?) -> Void) { self.handler = handler }
        func send(_ content: (any TVTopShelfContent)?) { handler(content) }
    }
}
