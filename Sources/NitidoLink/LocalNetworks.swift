import Foundation
import Darwin
import Network

/// One network of one of this Mac's interfaces: an address and its netmask, IPv4 (4 bytes) or IPv6 (16).
struct NetworkPrefix: Hashable, Sendable {
    let address: [UInt8]
    let mask: [UInt8]

    /// True when `other` (of the same family) has the same bits under the mask.
    func contains(_ other: [UInt8]) -> Bool {
        other.count == address.count && mask.count == address.count
            && zip(zip(address, other), mask).allSatisfy { pair, mask in pair.0 & mask == pair.1 & mask }
    }
}

/// What this Mac's networks are, as the sharer's listener judges where a connection came from (`InboundFilter`).
struct LocalNetworks: Sendable {
    /// Interfaces that are point-to-point links: VPN tunnels (`utun`, `ipsec`) and PPP. Never the local network.
    var pointToPoint: Set<String>
    /// The networks of the interfaces that are up and running, loopback and point-to-point links left out.
    var prefixes: [NetworkPrefix]

    init(pointToPoint: Set<String> = [], prefixes: [NetworkPrefix] = []) {
        self.pointToPoint = pointToPoint; self.prefixes = prefixes
    }

    /// This Mac's networks now, from `getifaddrs`.
    static func current() -> LocalNetworks {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return LocalNetworks() }
        defer { freeifaddrs(first) }
        var networks = LocalNetworks()
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            let name = String(cString: entry.pointee.ifa_name)
            if flags & IFF_POINTOPOINT != 0 { networks.pointToPoint.insert(name); continue }
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = bytes(entry.pointee.ifa_addr), let mask = bytes(entry.pointee.ifa_netmask, family: entry.pointee.ifa_addr?.pointee.sa_family),
                  mask.count == address.count
            else { continue }
            networks.prefixes.append(NetworkPrefix(address: address, mask: mask))
        }
        return networks
    }

    /// The address bytes of an IPv4 or IPv6 sockaddr, read no further than its `sa_len`: a netmask comes trimmed, and the
    /// bytes it leaves out are zero. `family` reads a netmask, whose own family field may be unset.
    static func bytes(_ sockaddr: UnsafeMutablePointer<sockaddr>?, family: sa_family_t? = nil) -> [UInt8]? {
        guard let sockaddr else { return nil }
        let (offset, count): (Int, Int)
        switch family ?? sockaddr.pointee.sa_family {
        case sa_family_t(AF_INET): (offset, count) = (MemoryLayout<sockaddr_in>.offset(of: \sockaddr_in.sin_addr)!, 4)
        case sa_family_t(AF_INET6): (offset, count) = (MemoryLayout<sockaddr_in6>.offset(of: \sockaddr_in6.sin6_addr)!, 16)
        default: return nil
        }
        let length = max(0, min(count, Int(sockaddr.pointee.sa_len) - offset))
        var out = [UInt8](repeating: 0, count: count)
        let raw = UnsafeRawPointer(sockaddr)
        for i in 0..<length { out[i] = raw.load(fromByteOffset: offset + i, as: UInt8.self) }
        return out
    }

    /// True when `address` is on one of these networks.
    func contains(_ address: [UInt8]) -> Bool { prefixes.contains { $0.contains(address) } }
}

/// Spec 13: the sharer takes connections from the local network only. Judged in the listener before a connection's
/// TLS handshake starts (`Advertiser`), so one from elsewhere never tests a code: it is cancelled at once and logged.
enum InboundFilter {
    /// Why a connection that came in from `remote` over `interfaceName` (of `interfaceType`) is turned away, or nil when
    /// it comes from the local network: an address that is private (RFC 1918, 169.254/16, fc00::/7, fe80::/10, loopback)
    /// or on one of this Mac's own networks, over an interface that is neither a VPN tunnel or other point-to-point link
    /// nor cellular. A private address on another VLAN (an mDNS reflector, spec 4) is let in; a public one on no network
    /// of this Mac (a globally routable IPv6 address the router lets through) is not, nor anything over a VPN.
    static func rejection(remote: NWEndpoint, interfaceName: String?, interfaceType: NWInterface.InterfaceType?,
                          networks: LocalNetworks) -> String? {
        if interfaceType == .cellular { return "it came over a cellular interface" }
        if let interfaceName, networks.pointToPoint.contains(interfaceName) {
            return "it came over \(interfaceName), a VPN tunnel or another point-to-point link"
        }
        guard case .hostPort(let host, _) = remote else { return "it came from \(remote), which is not an IP address" }
        switch host {
        case .ipv4(let address):
            return isLocal(address, networks) ? nil : "\(address) is neither a private address nor on this Mac's networks"
        case .ipv6(let address):
            if let scope = address.interface?.name, networks.pointToPoint.contains(scope) {
                return "it came over \(scope), a VPN tunnel or another point-to-point link"
            }
            if let mapped = address.asIPv4 {
                return isLocal(mapped, networks) ? nil : "\(mapped) is neither a private address nor on this Mac's networks"
            }
            let bytes = [UInt8](address.rawValue)
            let local = address.isLoopback || address.isLinkLocal || bytes.first.map { $0 & 0xfe == 0xfc } == true
                || networks.contains(bytes)
            return local ? nil : "\(String("\(address)".prefix { $0 != "%" })) is neither a private address nor on this Mac's networks"
        case .name(let name, _):
            return "it came from \(name), which is not an IP address"
        @unknown default:
            return "it came from \(host), which is not an IP address"
        }
    }

    /// Private (10/8, 172.16/12, 192.168/16), self-assigned (169.254/16), loopback, or on one of this Mac's networks.
    private static func isLocal(_ address: IPv4Address, _ networks: LocalNetworks) -> Bool {
        let b = [UInt8](address.rawValue)
        guard b.count == 4 else { return false }
        return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254) || b[0] == 127 || networks.contains(b)
    }

    /// `rejection` for a connection the listener just took: its remote endpoint, and the interface its path is on.
    static func rejection(of connection: NWConnection, networks: LocalNetworks) -> String? {
        let interface = connection.currentPath?.availableInterfaces.first
        return rejection(remote: connection.endpoint, interfaceName: interface?.name, interfaceType: interface?.type,
                         networks: networks)
    }
}
