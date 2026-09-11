import UIKit

/// Fetches and caches remote images (posters, backdrops, logos) for
/// `AsyncRemoteImage` and `BackdropLogoOverlay`.
///
/// Replaces `AsyncImage`, which has no retry: one transient failure leaves it
/// in `.failure` for its view's lifetime. Home is where that bites — hero plus
/// several rails fire a burst of concurrent requests at launch, against a
/// server that may be resizing images on the fly.
///
/// Adds retry with backoff (transient failures only, not a 404), a byte-cost
/// budgeted in-memory `NSCache`, a `URLCache`-backed session for cross-launch
/// reuse, and in-flight de-duplication so concurrent requests for one URL
/// share a single fetch.
actor RemoteImageLoader {
    static let shared = RemoteImageLoader()

    /// Modest on purpose: this runs during Home's initial burst, where
    /// retrying harder competes for the same connections.
    static let defaultMaxAttempts = 4

    /// Attempt `n` waits `retryBaseDelay * 2^n` — 0.5s/1s/2s, ~3.5s total.
    static let defaultRetryBaseDelay: Duration = .milliseconds(500)

    /// Larger budget (~9s over 5 attempts) for the one hero backdrop/logo per
    /// screen, via `AsyncRemoteImage.RetryPatience.extended`. Not the default:
    /// applying it to every rail image would worsen a cold server's burst.
    static let heroMaxAttempts = 5
    static let heroRetryBaseDelay: Duration = .milliseconds(600)

    /// Working set for several dozen rails' worth of artwork. A count-only
    /// limit let the cache reach ~365MB, since a 1600px backdrop and a 130pt
    /// thumbnail count the same against it.
    static let defaultTotalCostLimit = 150 * 1024 * 1024

    private let session: URLSession
    private let maxAttempts: Int
    private let retryBaseDelay: Duration
    /// `nonisolated(unsafe)` is safe — `NSCache` is thread-safe — and lets
    /// `cachedImage(for:)` answer with no actor hop, which callers seeding a
    /// view's initial `@State` need (see `LogoImageView.init`): a `Task`
    /// schedules its body rather than running it before first render.
    nonisolated(unsafe) private let memoryCache = NSCache<NSURL, UIImage>()
    private var inFlightTasks: [URL: Task<UIImage, Error>] = [:]

    /// Defaults to a dedicated session tuned for bursts of concurrent image
    /// requests. The tuning parameters are injectable so tests can exercise
    /// retry without real delays and eviction without 150MB of real images.
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
            // Above iOS's default of 6: Home's first paint fires hero plus
            // several rails at once, and the headroom reduces queuing.
            configuration.httpMaximumConnectionsPerHost = 8
            configuration.urlCache = URLCache(
                memoryCapacity: 32 * 1024 * 1024,
                diskCapacity: 256 * 1024 * 1024
            )
            configuration.requestCachePolicy = .useProtocolCachePolicy
            // No-op outside a UI test run. `URLProtocol.registerClass` only
            // reaches `URLSession.shared`, so this session must opt in
            // explicitly or every image escapes to the network.
            #if DEBUG
            UITestHarness.decorate(configuration)
            #endif
            self.session = URLSession(configuration: configuration)
        }
        self.maxAttempts = maxAttempts
        self.retryBaseDelay = retryBaseDelay
        // `totalCostLimit` is the binding limit; `countLimit` is only a guard
        // against pathologically many tiny images. At the ~700KB average
        // measured here, 500 items exceed the cost limit first.
        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = totalCostLimit
    }

    /// Synchronous cache peek — neither joins nor starts a fetch.
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    /// Returns the decoded image at `url` from cache, an in-flight request, or
    /// a fresh fetch with retry. Throws if every attempt fails.
    ///
    /// `maxAttempts`/`retryBaseDelay` override this instance's defaults for one
    /// call (see `heroMaxAttempts`). Concurrent callers requesting the same URL
    /// with different overrides share one task, so the first caller's win.
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

    /// Approximate decoded size, as the backing pixel buffer's own extent.
    /// Eviction needs proportionality, not precision, so this avoids the
    /// re-encode a `pngData()`-style measurement would cost.
    private nonisolated static func estimatedByteCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Runs off the actor so slow or failing requests don't block cache reads;
    /// only `image(for:)`'s cache and de-dup bookkeeping needs isolation.
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
