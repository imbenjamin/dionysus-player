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
///   out of view and back, or the same poster appearing in two rails) — with
///   a *byte-size* budget (`totalCostLimit`), not just a flat item count.
///   Measured live after scrolling through several dozen Home rails: a
///   count-only limit (an earlier version had only `countLimit = 500`, no
///   `cost:` passed to `setObject`) let the cache grow to ~365MB of decoded
///   bitmaps — a 1600px backdrop and a 130pt poster thumbnail count
///   identically toward a flat item cap despite being wildly different in
///   memory weight, and Home's dynamic genre/studio/actor/director rails
///   are heavy on the larger, backdrop-style images. `estimatedByteCost(of:)`
///   gives each entry its actual approximate decoded size so eviction
///   responds to real memory pressure instead.
/// - A dedicated `URLCache`-backed `URLSession` (bigger capacity than
///   `URLSession.shared`'s default) so cross-launch redisplay still benefits
///   from HTTP caching without every image needing to be in the in-memory
///   cache.
/// - In-flight request de-duplication: two views requesting the same URL at
///   the same time (common — the same poster can appear in multiple rails)
///   share one network request rather than firing two.
actor RemoteImageLoader {
    static let shared = RemoteImageLoader()

    /// Default transient-failure retries before giving up. Kept modest —
    /// this runs on Home's initial load where many images are already
    /// competing for bandwidth/connections; retrying too aggressively would
    /// make things worse, not better. Bumped from `3` to give a slow, cold
    /// local Jellyfin server (still warming up its own image-resizing
    /// pipeline right after launch) a bit more background runway before a
    /// tile settles into its failed placeholder — this retry is
    /// non-blocking (nothing in the UI waits on it), so the extra patience
    /// is cheap, unlike a page-level retry loop that blocks a visible
    /// loading state (see `HomeViewModel.reconnectRetrySchedule`'s own,
    /// deliberately shorter, reasoning).
    static let defaultMaxAttempts = 4

    /// Default base delay for retry backoff; attempt `n` (0-indexed) waits
    /// `retryBaseDelay * 2^n` — 0.5s/1s/2s, ~3.5s total across `
    /// defaultMaxAttempts` attempts. Bumped from 400ms alongside
    /// `defaultMaxAttempts`, same rationale.
    static let defaultRetryBaseDelay: Duration = .milliseconds(500)

    /// Extended-patience retry budget for the single most prominent image
    /// per screen (the hero backdrop/logo, via
    /// `AsyncRemoteImage.RetryPatience.extended`) — worth spending
    /// noticeably more attempts on than every other, smaller image on the
    /// page. ~9s total across 5 attempts (0.6s/1.2s/2.4s/4.8s). Not applied
    /// globally: a cold server already sees a burst of concurrent rail
    /// requests at launch, and multiplying every one of those by this
    /// budget would make a slow server's initial burst worse, not better.
    static let heroMaxAttempts = 5
    static let heroRetryBaseDelay: Duration = .milliseconds(600)

    /// Roughly the working set for smooth scrolling through several dozen
    /// rails' worth of posters/backdrops/logos without needing to re-fetch
    /// anything already seen this session, while staying well under the
    /// ~365MB an unbounded-by-size cache was observed reaching in practice
    /// (see this type's doc comment).
    static let defaultTotalCostLimit = 150 * 1024 * 1024

    private let session: URLSession
    private let maxAttempts: Int
    private let retryBaseDelay: Duration
    /// `nonisolated(unsafe)`: `NSCache` is documented thread-safe for
    /// concurrent access from any thread, so bypassing actor isolation for
    /// this specific property is safe — done so `cachedImage(for:)` below
    /// can answer synchronously, with no actor hop/suspension at all. That
    /// matters for callers seeding a view's *initial* `@State` from it (see
    /// `LogoImageView`'s `init`) — even an `await` that resolves near
    /// instantly still can't complete before that first render, since a
    /// `Task` schedules its body rather than running it inline.
    nonisolated(unsafe) private let memoryCache = NSCache<NSURL, UIImage>()
    private var inFlightTasks: [URL: Task<UIImage, Error>] = [:]

    /// - Parameters:
    ///   - session: defaults to a dedicated session (not `.shared`) tuned
    ///     for a burst of concurrent image requests, with a larger `URLCache`
    ///     than `URLSession.shared`'s default.
    ///   - maxAttempts/retryBaseDelay/totalCostLimit: overridable so tests
    ///     can exercise the retry path without real delays, or the eviction
    ///     path without needing 150MB of real images.
    init(
        session: URLSession? = nil,
        maxAttempts: Int = RemoteImageLoader.defaultMaxAttempts,
        retryBaseDelay: Duration = RemoteImageLoader.defaultRetryBaseDelay,
        totalCostLimit: Int = RemoteImageLoader.defaultTotalCostLimit
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
            // No-op outside a UI test run. `URLProtocol.registerClass` only
            // reaches `URLSession.shared`, so a session configured here has
            // to opt in explicitly or every image escapes to the network.
            #if DEBUG
            UITestHarness.decorate(configuration)
            #endif
            self.session = URLSession(configuration: configuration)
        }
        self.maxAttempts = maxAttempts
        self.retryBaseDelay = retryBaseDelay
        // `totalCostLimit` is the limit that actually matters in practice
        // (see this type's doc comment) — `countLimit` stays only as a
        // coarse secondary guard against an unrealistic pathological case
        // (a very large number of unusually tiny images); given the
        // ~700KB/image average observed live, 500 items' worth would
        // already exceed `totalCostLimit` well before `countLimit` did
        // anything on its own.
        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = totalCostLimit
    }

    /// Synchronous, non-isolated in-memory cache peek — doesn't join an
    /// in-flight fetch or trigger one; just answers "do we already have
    /// this decoded and in memory, right now." See `memoryCache`'s doc
    /// comment for why this is safe without actor isolation.
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    /// Returns the decoded image at `url`, using the in-memory cache,
    /// joining an in-flight request for the same URL if one exists, or
    /// fetching (with retry) otherwise. Throws if every attempt fails.
    ///
    /// - Parameters:
    ///   - maxAttempts/retryBaseDelay: override this instance's configured
    ///     defaults for just this call — used by `AsyncRemoteImage
    ///     .RetryPatience.extended` (the hero backdrop/logo) to pass
    ///     `heroMaxAttempts`/`heroRetryBaseDelay` instead of the smaller
    ///     defaults every other image uses. `nil` (the default) keeps this
    ///     instance's own configured values. If two callers request the
    ///     same URL concurrently with different overrides, the *first*
    ///     caller's values win for both, since they share one in-flight
    ///     `Task` — accepted as a rare, harmless trade-off rather than
    ///     something worth extra bookkeeping to avoid.
    func image(for url: URL, maxAttempts: Int? = nil, retryBaseDelay: Duration? = nil) async throws -> UIImage {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached
        }
        if let existing = inFlightTasks[url] {
            return try await existing.value
        }

        let resolvedMaxAttempts = maxAttempts ?? self.maxAttempts
        let resolvedRetryBaseDelay = retryBaseDelay ?? self.retryBaseDelay
        let task = Task<UIImage, Error> { [session] in
            try await Self.fetchWithRetry(
                url: url,
                session: session,
                maxAttempts: resolvedMaxAttempts,
                retryBaseDelay: resolvedRetryBaseDelay
            )
        }
        inFlightTasks[url] = task
        defer { inFlightTasks[url] = nil }

        let image = try await task.value
        memoryCache.setObject(image, forKey: url as NSURL, cost: Self.estimatedByteCost(of: image))
        return image
    }

    /// Approximate decoded, in-memory size of `image` — `bytesPerRow *
    /// height` is the standard proxy for this (matches the size of the
    /// actual pixel buffer backing a `CGImage`, which is what `Image IO`'s
    /// memory usage was dominated by when this was profiled live), cheap to
    /// compute (no re-encoding, unlike e.g. `pngData()`), and accurate
    /// enough for cache-eviction purposes — this doesn't need to be exact,
    /// just proportionate, so a 1600px backdrop is correctly weighted as
    /// much heavier than a 130pt poster thumbnail rather than counting the
    /// same as one entry each.
    private nonisolated static func estimatedByteCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
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
