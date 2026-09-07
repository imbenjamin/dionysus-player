import Foundation
@testable import Dionysus

/// A `URLProtocol` stub that intercepts every request made on a session
/// configured with it, so tests can script `JellyfinAPIClient`'s responses
/// instead of talking to a real server.
///
/// Usage: create a session with `MockURLProtocol.makeSession()`, inject it
/// into a `JellyfinAPIClient`, then set `requestHandler` before making the
/// call under test. Reset it in `tearDown()` so one test's stub can't leak
/// into the next.
final class MockURLProtocol: URLProtocol {
    struct UnhandledRequest: Error {}

    /// Inspects the outgoing request and returns the response/body to hand
    /// back, or throws to simulate a transport failure.
    ///
    /// `nonisolated(unsafe)`: mutated only from test methods, which XCTest
    /// runs serially within a single test case, and read only while that
    /// case's session is loading — never touched concurrently in practice.
    /// Same justification as the formatter statics in `JellyfinCoding.swift`.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// The most recent request this protocol saw, for tests that want to
    /// assert on method/headers/query rather than just the decoded result.
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Call from `tearDown()` so a forgotten stub doesn't affect later tests.
    static func reset() {
        requestHandler = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lastRequest = request
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: UnhandledRequest())
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// Flattens this request's query items into a `[String: String]` for
    /// easy assertions. Deliberately a plain, non-isolated computed property
    /// (not a method on some `@MainActor` test class) so it's safe to call
    /// from inside a `MockURLProtocol.requestHandler`, which the URL Loading
    /// System invokes off the main actor.
    var queryDictionary: [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    /// `httpBody` reads back as `nil` here even when the client set it:
    /// `URLSession`'s async `data(for:)` moves the payload into
    /// `httpBodyStream` before handing the request to a custom
    /// `URLProtocol`. This drains whichever one is actually populated, so
    /// tests can assert on the request body regardless of which API sent it.
    var capturedHTTPBody: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}

extension MockURLProtocol {
    /// Convenience for the common case: encode a Jellyfin-shaped JSON body
    /// with a status code, keyed to the request's own URL.
    static func jsonResponse(for request: URLRequest, status: Int = 200, body: Data) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body)
    }

    static func encodedJSONResponse<T: Encodable>(for request: URLRequest, status: Int = 200, value: T) throws -> (HTTPURLResponse, Data) {
        jsonResponse(for: request, status: status, body: try JellyfinJSON.encoder.encode(value))
    }
}
