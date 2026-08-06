import UIKit

/// Fetches and caches remote images (posters, backdrops, logos), used by
/// `AsyncRemoteImage` and `BackdropLogoOverlay` instead of `AsyncImage`'s
/// built-in loading.
///
/// Plain `AsyncImage` (backed by `URLSession.shared`) has no retry: a single
/// transient failure — a timeout, a dropped connection, the server briefly
/// busy resizing an image on the fly — leaves that `AsyncImage` permanently
/// in `.failure` for the rest of its view's lifetime, since nothing re-runs
/// the load. That's a real problem on Home specifically: the hero rail and
/// several content rails all appear at once, each firing off a handful of
/// image requests simultaneously, so a self-hosted Jellyfin server doing
/// on-the-fly image resizing (see `ImageURLBuilder`'s `maxWidth` param) sees
/// a burst of concurrent requests right at launch — exactly the situation
/// most likely to produce transient failures. Reported symptom ("images
/// don't load, but they do exist") matches this: no retry means one bad
/// request is permanent.
///
/// This type fixes that with:
/// - Retry with backoff for transient failures (timeouts, dropped
///   connections, 5xx) — not for e.g. a genuine 404, which won't be fixed by
///   trying again.
/// - An in-memory `NSCache`, so images already seen this session redisplay
///   instantly without a network round-trip at all (e.g. scrolling a rail
///   out of view and back, or the same poster appearing in two rails).
/// - A dedicated `URLCache`-backed `URLSession` (bigger capacity than
///   `URLSession.shared`'s default) so cross-launch redisplay still benefits
///   from HTTP caching without every image needing to be in the in-memory
///   cache.
/// - In-flight request de-duplication: two views requesting the same URL at
///   the same time (common — the same poster can appear in multiple rails)
///   share one network request rather than firing two.
actor RemoteImageLoader {
    static let shared = RemoteImageLoader()

    /// Default transient-failure retries before giving up. Kept small — this
    /// runs on Home's initial load where many images are already competing
    /// for bandwidth/connections; retrying too aggressively would make
    /// things worse, not better.
    static let defaultMaxAttempts = 3

    /// Default base delay for retry backoff; attempt `n` (0-indexed) waits
    /// `retryBaseDelay * 2^n` — 0.4s, 0.8s.
    static let defaultRetryBaseDelay: Duration = .milliseconds(400)

    private let session: URLSession
    private let maxAttempts: Int
    private let retryBaseDelay: Duration
    private let memoryCache = NSCache<NSURL, UIImage>()
    private var inFlightTasks: [URL: Task<UIImage, Error>] = [:]

    /// - Parameters:
    ///   - session: defaults to a dedicated session (not `.shared`) tuned
    ///     for a burst of concurrent image requests, with a larger `URLCache`
    ///     than `URLSession.shared`'s default.
    ///   - maxAttempts/retryBaseDelay: overridable so tests can exercise the
    ///     retry path without real delays.
    init(
        session: URLSession? = nil,
        maxAttempts: Int = RemoteImageLoader.defaultMaxAttempts,
        retryBaseDelay: Duration = RemoteImageLoader.defaultRetryBaseDelay
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            // Default is already 6 on iOS, but images are on the hot path
            // for Home's very first paint (hero + several rails firing at
            // once) — a little extra headroom reduces queuing.
            configuration.httpMaximumConnectionsPerHost = 8
            configuration.urlCache = URLCache(
                memoryCapacity: 32 * 1024 * 1024,
                diskCapacity: 256 * 1024 * 1024
            )
            configuration.requestCachePolicy = .useProtocolCachePolicy
            self.session = URLSession(configuration: configuration)
        }
        self.maxAttempts = maxAttempts
        self.retryBaseDelay = retryBaseDelay
        memoryCache.countLimit = 500
    }

    /// Returns the decoded image at `url`, using the in-memory cache,
    /// joining an in-flight request for the same URL if one exists, or
    /// fetching (with retry) otherwise. Throws if every attempt fails.
    func image(for url: URL) async throws -> UIImage {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached
        }
        if let existing = inFlightTasks[url] {
            return try await existing.value
        }

        let task = Task<UIImage, Error> { [session, maxAttempts, retryBaseDelay] in
            try await Self.fetchWithRetry(
                url: url,
                session: session,
                maxAttempts: maxAttempts,
                retryBaseDelay: retryBaseDelay
            )
        }
        inFlightTasks[url] = task
        defer { inFlightTasks[url] = nil }

        let image = try await task.value
        memoryCache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// `nonisolated` + `static`: runs the actual retry loop off the actor so
    /// slow/failing network calls don't block other callers' cache reads —
    /// only the surrounding cache/de-dup bookkeeping in `image(for:)` needs
    /// actor isolation.
    private nonisolated static func fetchWithRetry(
        url: URL,
        session: URLSession,
        maxAttempts: Int,
        retryBaseDelay: Duration
    ) async throws -> UIImage {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<maxAttempts {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                guard let image = UIImage(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }
                return image
            } catch {
                lastError = error
                if attempt < maxAttempts - 1 {
                    try? await Task.sleep(for: retryBaseDelay * (1 << attempt))
                }
            }
        }
        throw lastError
    }
}
