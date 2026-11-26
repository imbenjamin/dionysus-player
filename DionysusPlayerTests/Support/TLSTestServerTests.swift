import XCTest
@testable import Dionysus

/// Proves the in-process TLS listener works inside the unit-test host, and
/// answers whether a per-task delegate sees `URLSession.shared`'s server-trust
/// challenge (the feature's trust handling depends on it).
final class TLSTestServerTests: XCTestCase {
    /// Accepts any server trust and records which hosts were challenged.
    private final class TrustSpy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [String] = []
        var challengeHosts: [String] { lock.withLock { hosts } }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            lock.withLock { hosts.append(challenge.protectionSpace.host) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    func testURLSessionWithPerTaskDelegateReceivesTheServerTrustChallenge() async throws {
        let server = try await TLSTestServer(identity: "selfSignedA")
        defer { server.stop() }
        let spy = TrustSpy()

        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: server.baseURL), delegate: spy)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("TLS Test"))
        XCTAssertEqual(spy.challengeHosts, ["127.0.0.1"])
    }

    func testWithoutADelegateTheHandshakeIsRefused() async throws {
        let server = try await TLSTestServer(identity: "selfSignedA")
        defer { server.stop() }

        do {
            _ = try await URLSession.shared.data(from: server.baseURL)
            XCTFail("an untrusted certificate must not load")
        } catch let error as URLError {
            let expected: [URLError.Code] = [.serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                                             .secureConnectionFailed]
            XCTAssertTrue(expected.contains(error.code), "unexpected \(error.code)")
            let value = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey]
            XCTAssertNotNil(value, "the failing trust should ride along on the error")
            if let value {
                XCTAssertEqual(CFGetTypeID(value as CFTypeRef), SecTrustGetTypeID())
            }
        }
    }
}
