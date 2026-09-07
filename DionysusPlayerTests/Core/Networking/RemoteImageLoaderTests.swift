import XCTest
import UIKit
@testable import Dionysus

/// Exercises `RemoteImageLoader` against `MockURLProtocol` — the same
/// fake-server seam `JellyfinAPIClientTests` uses — so retry, caching, and
/// de-duplication behavior is verified without a real network.
final class RemoteImageLoaderTests: XCTestCase {
    private let url = URL(string: "https://example.com/Items/1/Images/Primary")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeLoader(maxAttempts: Int = 3) -> RemoteImageLoader {
        RemoteImageLoader(
            session: MockURLProtocol.makeSession(),
            maxAttempts: maxAttempts,
            // Real backoff delays would make the retry/exhaustion tests slow
            // (and the dedup/success tests don't hit this path at all) —
            // near-zero so the whole suite stays fast.
            retryBaseDelay: .milliseconds(1)
        )
    }

    private nonisolated static func makeImageData() -> Data {
        // Explicit scale 1 — PNG data doesn't carry scale metadata, so
        // decoding it back via `UIImage(data:)` always assumes scale 1
        // regardless of what scale this was rendered at. Without pinning
        // this, the renderer defaults to the simulator's screen scale (e.g.
        // 3x), and the round-tripped image's `.size` would come back as
        // pixel dimensions instead of the intended point size.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return image.pngData()!
    }

    // MARK: - Success

    func test_image_returnsDecodedImageOnFirstSuccess() async throws {
        let counter = RequestCounter()
        MockURLProtocol.requestHandler = { [imageData = Self.makeImageData()] request in
            counter.increment()
            return MockURLProtocol.jsonResponse(for: request, body: imageData)
        }

        let image = try await makeLoader().image(for: url)

        XCTAssertEqual(image.size, CGSize(width: 2, height: 2))
        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - Retry

    func test_image_retriesTransientFailureThenSucceeds() async throws {
        let counter = RequestCounter()
        MockURLProtocol.requestHandler = { [imageData = Self.makeImageData()] request in
            let attempt = counter.increment()
            // Fail the first two attempts (connection-lost style transport
            // error), succeed on the third.
            if attempt < 3 {
                throw URLError(.networkConnectionLost)
            }
            return MockURLProtocol.jsonResponse(for: request, body: imageData)
        }

        let image = try await makeLoader(maxAttempts: 3).image(for: url)

        XCTAssertEqual(image.size, CGSize(width: 2, height: 2))
        XCTAssertEqual(counter.count, 3)
    }

    func test_image_retriesOnServerErrorStatusCode() async throws {
        let counter = RequestCounter()
        MockURLProtocol.requestHandler = { [imageData = Self.makeImageData()] request in
            let attempt = counter.increment()
            if attempt < 2 {
                return MockURLProtocol.jsonResponse(for: request, status: 503, body: Data())
            }
            return MockURLProtocol.jsonResponse(for: request, body: imageData)
        }

        let image = try await makeLoader().image(for: url)

        XCTAssertEqual(image.size, CGSize(width: 2, height: 2))
        XCTAssertEqual(counter.count, 2)
    }

    func test_image_throwsAfterExhaustingAllRetries() async {
        let counter = RequestCounter()
        MockURLProtocol.requestHandler = { request in
            counter.increment()
            throw URLError(.timedOut)
        }

        do {
            _ = try await makeLoader(maxAttempts: 3).image(for: url)
            XCTFail("Expected image(for:) to throw after exhausting retries")
        } catch {
            XCTAssertEqual(counter.count, 3)
        }
    }

    // MARK: - Per-call retry overrides

    /// `image(for:maxAttempts:retryBaseDelay:)`'s per-call overrides
    /// (used by `AsyncRemoteImage.RetryPatience.extended` for the hero
    /// backdrop/logo) must win over this instance's own configured
    /// defaults — configure the loader for only 2 attempts, but request 4
    /// for this one call, and confirm all 4 actually happen rather than
    /// stopping at the instance's own smaller budget.
    func test_image_perCallMaxAttemptsOverridesInstanceDefault() async throws {
        let counter = RequestCounter()
        MockURLProtocol.requestHandler = { request in
            counter.increment()
            throw URLError(.timedOut)
        }

        do {
            _ = try await makeLoader(maxAttempts: 2).image(for: url, maxAttempts: 4, retryBaseDelay: .milliseconds(1))
            XCTFail("Expected image(for:) to throw after exhausting the overridden retry count")
        } catch {
            XCTAssertEqual(counter.count, 4)
        }
    }

    // MARK: - Caching

    func test_image_secondCallForSameURLIsServedFromCacheWithoutHittingNetwork() async throws {
        let counter = RequestCounter()
        MockURLProtocol.requestHandler = { [imageData = Self.makeImageData()] request in
            counter.increment()
            return MockURLProtocol.jsonResponse(for: request, body: imageData)
        }
        let loader = makeLoader()

        _ = try await loader.image(for: url)
        _ = try await loader.image(for: url)

        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - De-duplication

    func test_image_concurrentRequestsForSameURLShareOneNetworkCall() async throws {
        let counter = RequestCounter()
        MockURLProtocol.requestHandler = { [imageData = Self.makeImageData()] request in
            counter.increment()
            return MockURLProtocol.jsonResponse(for: request, body: imageData)
        }
        let loader = makeLoader()
        // Copied to a local rather than referencing `self.url` directly —
        // under Swift 6 strict concurrency, `async let` spawns a child task
        // and capturing a property off the (non-Sendable) XCTestCase `self`
        // into it is flagged as a potential data race even though nothing
        // else touches it concurrently here.
        let requestURL = url

        async let first = loader.image(for: requestURL)
        async let second = loader.image(for: requestURL)
        let (firstImage, secondImage) = try await (first, second)

        XCTAssertEqual(firstImage.size, CGSize(width: 2, height: 2))
        XCTAssertEqual(secondImage.size, CGSize(width: 2, height: 2))
        XCTAssertEqual(counter.count, 1)
    }
}

/// Thread-safe request counter — `MockURLProtocol.requestHandler` runs on
/// whatever background queue the URL Loading System chooses, and the
/// de-duplication test deliberately issues concurrent requests, so a plain
/// `var` isn't safe here.
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
