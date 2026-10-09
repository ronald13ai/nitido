import Foundation
import Darwin
import Network

/// One IPv4 address of one of this Mac's interfaces, as `getifaddrs` lists it.
struct IPv4Interface {
    let name: String
    let flags: Int32
    let address: IPv4Address
    let mask: IPv4Address?

    var isUpAndRunning: Bool { flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 }
    var isLoopback: Bool { flags & IFF_LOOPBACK != 0 }
    /// A point-to-point link, a VPN tunnel above all: not the local network.
    var isPointToPoint: Bool { flags & IFF_POINTOPOINT != 0 }

    /// Every IPv4 address of every interface, in the order the system lists them.
    static func all() -> [IPv4Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { entry in
            guard let address = ipv4(entry.pointee.ifa_addr) else { return nil }
            return IPv4Interface(name: String(cString: entry.pointee.ifa_name), flags: Int32(entry.pointee.ifa_flags),
                                 address: address, mask: ipv4(entry.pointee.ifa_netmask))
        }
    }

    private static func ipv4(_ sockaddr: UnsafeMutablePointer<sockaddr>?) -> IPv4Address? {
        guard let sockaddr, sockaddr.pointee.sa_family == UInt8(AF_INET) else { return nil }
        let raw = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Data($0) } }
        return IPv4Address(raw)
    }
}

/// An IPv4 network one of this Mac's interfaces is on: that interface's address and netmask. A viewer dials only the
/// published addresses on one of its own networks (`Peer.routes(on:)`).
public struct IPv4Subnet: Hashable, Sendable {
    public let address: IPv4Address
    public let mask: IPv4Address

    public init(address: IPv4Address, mask: IPv4Address) { self.address = address; self.mask = mask }

    /// True when `other` is on this network: the same bits under the mask.
    public func contains(_ other: IPv4Address) -> Bool {
        zip(zip(address.rawValue, other.rawValue), mask.rawValue).allSatisfy { pair, mask in pair.0 & mask == pair.1 & mask }
    }

    /// The networks of this Mac's interfaces that are up and running. Point-to-point links (VPN tunnels) are left out,
    /// as `Advertiser.localIPv4Addresses` leaves them out of what a sharer publishes; loopback is in, which costs
    /// nothing (`Browser.peer` takes no loopback address from a TXT record) and lets two copies on one Mac reach each
    /// other through it.
    public static func local() -> [IPv4Subnet] {
        IPv4Interface.all().compactMap { interface in
            guard interface.isUpAndRunning, !interface.isPointToPoint, let mask = interface.mask else { return nil }
            return IPv4Subnet(address: interface.address, mask: mask)
        }
    }
}
