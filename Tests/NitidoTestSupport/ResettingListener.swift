import Foundation
import Darwin

/// A TCP listener on 127.0.0.1 that takes each connection, reads what the client sends first (a TLS ClientHello), then
/// resets it (an abortive close, RST): a host that accepted the connection and then cut it, as a sharer may after a
/// failed handshake. It counts the connections it took.
public final class ResettingListener: @unchecked Sendable {
    private let socket: Int32
    private let lock = NSLock()
    private var taken = 0
    private var stopped = false

    public init() throws {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socket, 8) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(socket)
            throw error
        }
    }

    /// Connections taken so far.
    public var accepted: Int { lock.withLock { taken } }

    /// The port it listens on; it takes connections from now until `stop`.
    public func start() -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        let thread = Thread { [self] in serve() }
        thread.start()
        return UInt16(bigEndian: address.sin_port)
    }

    public func stop() { lock.withLock { stopped = true } }

    private func serve() {
        while !lock.withLock({ stopped }) {
            var ready = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 50) > 0 else { continue }
            let client = accept(socket, nil, nil)
            guard client >= 0 else { continue }
            lock.withLock { taken += 1 }
            // What the client sends first, waited for at most a second.
            var first = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            if poll(&first, 1, 1000) > 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = read(client, &buffer, buffer.count)
            }
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(client, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
            close(client)
        }
        close(socket)
    }
}
