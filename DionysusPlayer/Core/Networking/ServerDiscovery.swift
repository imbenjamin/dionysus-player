import Darwin
import Foundation

/// A Jellyfin server that answered a discovery probe on the local network.
struct DiscoveredServer: Identifiable, Hashable, Sendable {
    /// The server's `SystemId` — stable across restarts and address changes,
    /// so it is what de-duplicates one server answering on several interfaces.
    let id: String
    let name: String
    /// Where the server says to reach it, including any base path
    /// (`http://192.168.0.222:8096/flix`) — exactly what the address field takes.
    let address: URL

    /// The address as the user would type it: no scheme, no trailing slash.
    var displayAddress: String {
        var text = address.absoluteString
        if let schemeEnd = text.range(of: "://") {
            text = String(text[schemeEnd.upperBound...])
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

enum ServerDiscoveryError: Error, Equatable {
    /// No Wi-Fi or Ethernet interface with an IPv4 address — on cellular only,
    /// say. There is no local network to scan.
    case noLocalNetwork
    /// Every probe was refused before it left the device, which is how iOS
    /// reports Local Network access being denied (there is no API to ask).
    case localNetworkAccessDenied
}

/// Finds Jellyfin servers on the local network.
///
/// A protocol so `ServerSetupViewModel` can be tested, and the UI-test harness
/// can answer, without touching a real network.
protocol ServerDiscovering: Sendable {
    /// Servers as they answer, each at most once. Finishes when the scan
    /// window closes; throws `ServerDiscoveryError` if it couldn't scan at all.
    func discoverServers() -> AsyncThrowingStream<DiscoveredServer, Error>
}

// MARK: - Protocol

/// Jellyfin's client auto-discovery protocol: a UDP datagram to port 7359
/// containing `who is JellyfinServer?`, answered with a JSON
/// `ServerDiscoveryInfo` sent back to the sender. See `AutoDiscoveryHost.cs`
/// in jellyfin/jellyfin — it matches the phrase anywhere in the datagram,
/// case-insensitively, and can be switched off server-side (Networking →
/// "Enable Auto Discovery", on by default).
enum JellyfinDiscoveryProtocol {
    static let port: UInt16 = 7359
    static let probe = Data("who is JellyfinServer?".utf8)

    /// Serialized by `System.Text.Json` with no naming policy, so PascalCase.
    /// `EndpointAddress` is also sent and always null in practice.
    private struct Reply: Decodable {
        let address: String
        let id: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case address = "Address"
            case id = "Id"
            case name = "Name"
        }
    }

    /// Parses one reply datagram. `nil` for anything that isn't a well-formed
    /// reply with an http(s) address — the port is shared with nothing else by
    /// convention, but not by guarantee.
    static func parseReply(_ data: Data) -> DiscoveredServer? {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              !reply.id.isEmpty,
              let url = URL(string: reply.address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        let name = reply.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return DiscoveredServer(id: reply.id, name: name.isEmpty ? host : name, address: url)
    }
}

// MARK: - Subnet

/// One IPv4 interface's subnet, and the hosts on it worth probing.
struct LocalSubnet: Equatable {
    /// Host byte order throughout, converted only at the socket boundary.
    let address: UInt32
    let netmask: UInt32

    /// Anything wider than this is narrowed to the device's own /24: a /16
    /// would be 65,534 datagrams, and home networks that wide still put their
    /// devices next to each other.
    static let widestScannedPrefix = 22

    var prefixLength: Int { netmask.nonzeroBitCount }

    /// Every host address on the subnet except the network and broadcast
    /// addresses. Empty for /31 and /32.
    ///
    /// Includes the device's own address: an iPhone never runs the server, but
    /// the Simulator shares its Mac's interfaces, and a Mac running Jellyfin is
    /// the usual development setup.
    var hostAddresses: [UInt32] {
        let mask = prefixLength < Self.widestScannedPrefix ? UInt32(0xFFFF_FF00) : netmask
        let network = address & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return Array((network + 1)..<broadcast)
    }

    /// The device's IPv4 subnets on Wi-Fi and wired interfaces (`en*`) — never
    /// cellular (`pdp_ip*`), VPN tunnels (`utun*`) or link-local addresses,
    /// none of which would have a Jellyfin server next to them.
    static func current() -> [LocalSubnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var subnets: [LocalSubnet] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard String(cString: entry.ifa_name).hasPrefix("en"),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = entry.ifa_netmask
            else { continue }
            let subnet = LocalSubnet(
                address: ipv4(address),
                netmask: ipv4(netmask)
            )
            // 169.254/16: no DHCP answer, so nothing else is on it either.
            guard subnet.address >> 16 != 0xA9FE, !subnets.contains(subnet) else { continue }
            subnets.append(subnet)
        }
        return subnets
    }

    private static func ipv4(_ sockaddr: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
    }
}

// MARK: - Live scan

/// Scans every host on the local subnet(s) with a unicast discovery probe.
///
/// **Unicast, not broadcast.** Jellyfin's own clients broadcast the probe, but
/// on iOS sending to a broadcast or multicast address needs the restricted
/// `com.apple.developer.networking.multicast` entitlement, granted only on
/// request to Apple. The server answers the phrase in *any* datagram, so one
/// probe per host reaches the same servers — a /24 is 254 datagrams of 22
/// bytes — and needs only the Local Network permission, which iOS prompts for
/// on the first probe. The cost is that a server on another subnet isn't
/// found either way; broadcasts don't cross routers.
///
/// **Rounds.** Probes go out several times: the first round usually lands
/// while iOS is still showing the Local Network prompt (every send refused),
/// and a host that has to be ARP-resolved first can drop its first datagram.
/// The scan waits up to `permissionGrace` for any send to succeed, then
/// listens for `listenWindow` after that.
struct LANServerDiscovery: ServerDiscovering {
    var roundInterval: TimeInterval = 1
    var listenWindow: TimeInterval = 3
    var permissionGrace: TimeInterval = 8

    func discoverServers() -> AsyncThrowingStream<DiscoveredServer, Error> {
        AsyncThrowingStream { continuation in
            let cancelled = CancellationFlag()
            continuation.onTermination = { _ in cancelled.set() }
            let scan = self
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try scan.run(cancelled: cancelled) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Blocking; runs on a background queue for at most
    /// `permissionGrace + listenWindow` seconds.
    private func run(cancelled: CancellationFlag, found: (DiscoveredServer) -> Void) throws {
        let targets = LocalSubnet.current().flatMap(\.hostAddresses)
        guard !targets.isEmpty else { throw ServerDiscoveryError.noLocalNetwork }

        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw ServerDiscoveryError.noLocalNetwork }
        defer { close(socket) }
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)

        let start = Date()
        var anySendSucceeded = false
        var deadline = start.addingTimeInterval(permissionGrace)
        var nextRound = start
        var seen = Set<String>()

        while !cancelled.isSet, Date() < deadline {
            if Date() >= nextRound {
                if send(to: targets, on: socket), !anySendSucceeded {
                    anySendSucceeded = true
                    deadline = Date().addingTimeInterval(listenWindow)
                }
                nextRound = Date().addingTimeInterval(roundInterval)
            }

            var pollDescriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 100) > 0 else { continue }
            while let datagram = receive(on: socket) {
                if let server = JellyfinDiscoveryProtocol.parseReply(datagram), seen.insert(server.id).inserted {
                    found(server)
                }
            }
        }

        if !anySendSucceeded, !cancelled.isSet {
            throw ServerDiscoveryError.localNetworkAccessDenied
        }
    }

    /// One probe to every target. `true` if any send was accepted — the only
    /// available signal that Local Network access has been granted, since a
    /// denied app has every send refused with `EHOSTUNREACH`.
    private func send(to targets: [UInt32], on socket: Int32) -> Bool {
        var anyAccepted = false
        JellyfinDiscoveryProtocol.probe.withUnsafeBytes { bytes in
            for target in targets {
                var destination = sockaddr_in()
                destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                destination.sin_family = sa_family_t(AF_INET)
                destination.sin_port = JellyfinDiscoveryProtocol.port.bigEndian
                destination.sin_addr = in_addr(s_addr: target.bigEndian)
                let sent = withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socket, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if sent >= 0 { anyAccepted = true }
            }
        }
        return anyAccepted
    }

    private func receive(on socket: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(socket, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return Data(buffer[..<count])
    }
}

/// Lets `AsyncThrowingStream.onTermination` stop the blocking scan loop.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
