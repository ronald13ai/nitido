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

    /// The IPv4 address in one of `getifaddrs`'s sockaddrs, read no further than its `sa_len`: a netmask comes trimmed
    /// (5 bytes for 255.0.0.0, 7 for 255.255.255.0), and the bytes it leaves out are zero, not whatever follows it in
    /// memory. Internal so a test can hand it a trimmed one.
    static func ipv4(_ sockaddr: UnsafeMutablePointer<sockaddr>?) -> IPv4Address? {
        guard let sockaddr, sockaddr.pointee.sa_family == UInt8(AF_INET) else { return nil }
        let offset = MemoryLayout<sockaddr_in>.offset(of: \sockaddr_in.sin_addr)!
        let length = max(0, min(4, Int(sockaddr.pointee.sa_len) - offset))
        var bytes = [UInt8](repeating: 0, count: 4)
        let raw = UnsafeRawPointer(sockaddr)
        for i in 0..<length { bytes[i] = raw.load(fromByteOffset: offset + i, as: UInt8.self) }
        return IPv4Address(Data(bytes))
    }
}

/// An IPv4 network one of this Mac's interfaces is on: that interface's address and netmask. A viewer dials the
/// published addresses on one of its own networks before the others (`Peer.dialled(on:)`).
public struct IPv4Subnet: Hashable, Sendable {
    public let address: IPv4Address
    public let mask: IPv4Address

    public init(address: IPv4Address, mask: IPv4Address) { self.address = address; self.mask = mask }

    /// True when `other` is on this network: the same bits under the mask.
    public func contains(_ other: IPv4Address) -> Bool {
        zip(zip(address.rawValue, other.rawValue), mask.rawValue).allSatisfy { pair, mask in pair.0 & mask == pair.1 & mask }
    }

    /// The networks of this Mac's interfaces that are up and running. Loopback and point-to-point links (VPN tunnels)
    /// are left out, as `Advertiser.localIPv4Addresses` leaves them out of what a sharer publishes: no published address
    /// is ever on them (`Browser.peer` takes no loopback address from a TXT record). Two copies on one Mac meet on the
    /// network of the address the sharer publishes, Wi-Fi or Ethernet.
    public static func local() -> [IPv4Subnet] {
        IPv4Interface.all().compactMap { interface in
            guard interface.isUpAndRunning, !interface.isLoopback, !interface.isPointToPoint, let mask = interface.mask
            else { return nil }
            return IPv4Subnet(address: interface.address, mask: mask)
        }
    }
}
