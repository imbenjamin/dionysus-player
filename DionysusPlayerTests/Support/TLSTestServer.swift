import Foundation
import Network
import Security

/// A real HTTPS listener on loopback, so tests can drive `URLSession` through
/// an actual TLS handshake with a chosen certificate. Answers every request
/// 200 with a Jellyfin-shaped `/System/Info/Public` body.
final class TLSTestServer: @unchecked Sendable {
    static let body = #"{"ServerName":"TLS Test","Version":"10.11.0","Id":"tls-test"}"#

    private let queue = DispatchQueue(label: "TLSTestServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: UInt16 = 0

    var port: UInt16 { lock.withLock { boundPort } }
    var baseURL: URL { URL(string: "https://127.0.0.1:\(port)")! }

    init(identity: String) async throws {
        try await start(identity: identity, port: .any)
    }

    /// Serves `name`'s certificate from now on, on the same port. Existing
    /// connections are dropped; sessions reconnect and handshake again.
    func replaceIdentity(_ name: String) {
        let port = self.port
        stop()
        // The old listener's socket closes asynchronously: retry the rebind.
        for _ in 0..<50 {
            if (try? startSync(identity: name, port: NWEndpoint.Port(rawValue: port)!)) != nil { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        fatalError("TLSTestServer couldn't rebind port \(port)")
    }

    func stop() {
        let (old, conns) = lock.withLock { () -> (NWListener?, [NWConnection]) in
            let result = (listener, connections)
            listener = nil
            connections = []
            return result
        }
        old?.cancel()
        conns.forEach { $0.cancel() }
    }

    private func start(identity: String, port: NWEndpoint.Port) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try launch(identity: identity, port: port) { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func startSync(identity: String, port: NWEndpoint.Port) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<Result<Void, Error>?>(nil)
        try launch(identity: identity, port: port) {
            result.set($0)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success, case .success? = result.get() else {
            stop()
            throw URLError(.cannotConnectToHost)
        }
    }

    private func launch(identity: String, port: NWEndpoint.Port,
                        ready: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(TLSFixtures.identity(identity)) else {
            throw URLError(.cannotLoadFromNetwork)
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        let parameters = NWParameters(tls: tls)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: port)
        let once = LockedBox(false)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                if let self, let listener, let p = listener.port?.rawValue {
                    self.lock.withLock { self.boundPort = p }
                }
                if once.swap(true) == false { ready(.success(())) }
            case .failed(let error):
                if once.swap(true) == false { ready(.failure(error)) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener else { connection.cancel(); return }
            self.accept(connection, from: listener)
        }
        lock.withLock { self.listener = listener }
        listener.start(queue: queue)
    }

    /// A connection reaching a listener `stop()` already swapped out is
    /// cancelled, never kept: `stop()` has already cancelled the list it
    /// would join.
    private func accept(_ connection: NWConnection, from listener: NWListener) {
        let isCurrent = lock.withLock { () -> Bool in
            guard self.listener === listener else { return false }
            connections.append(connection)
            return true
        }
        guard isCurrent else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak connection] state in
            if case .ready = state, let connection { self.serve(connection, buffer: Data()) }
        }
        connection.start(queue: queue)
    }

    /// Reads until the request's blank line, answers, and loops for keep-alive.
    private func serve(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                let payload = Data(Self.body.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: keep-alive\r\n\r\n"
                connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in })
            }
            if error != nil || isComplete {
                connection.cancel()
            } else {
                self.serve(connection, buffer: buffer)
            }
        }
    }
}

/// A value shared between the listener's queue and the caller.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
    func swap(_ new: Value) -> Value { lock.withLock { let old = value; value = new; return old } }
}
