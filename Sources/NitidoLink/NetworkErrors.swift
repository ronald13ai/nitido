import Foundation
import Network
import dnssd

extension NWError {
    /// Local Network access is off for Nítido (DNS-SD PolicyDenied): the network failure a person fixes on this Mac.
    var isLocalNetworkDenied: Bool {
        if case .dns(let code) = self, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { return true }
        return false
    }

    static let localNetworkOff = "Local Network access is off for Nítido. Turn it on in System Settings, Privacy and Security, Local Network."

    /// The error's number, for whoever reads the log alongside the sentence: " (error 61)".
    var statusNote: String { " (error \(errorCode))" }

    /// For a listener or a browser, which have no other Mac to name: what stopped working, in plain words, with the fix
    /// when a person can make one. The system's own description ("The operation couldn't be completed. (Network.NWError
    /// error 61...)") is for the log only.
    var plainDescription: String {
        if isLocalNetworkDenied { return Self.localNetworkOff }
        switch self {
        case .posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.EADDRNOTAVAIL):
            return "This Mac is not connected to a network."
        case .posix(.EADDRINUSE):
            return "Another app is using the network port Nítido listens on\(statusNote)."
        case .dns:
            return "Bonjour, which finds Macs on the local network, is not working\(statusNote)."
        default:
            return "The local network is not available\(statusNote)."
        }
    }

    /// What a failed connection says about the other Mac (`mac`, the name to show), as one sentence: "Ronald's MacBook
    /// Pro is no longer sharing." Local Network off is said with its fix instead, since it is this Mac's.
    func plainSentence(about mac: String) -> String {
        if isLocalNetworkDenied { return Self.localNetworkOff }
        switch self {
        case .posix(.ECONNREFUSED):
            return "\(mac) is no longer sharing."
        case .posix(.ECONNRESET), .posix(.ECONNABORTED), .posix(.EPIPE):
            return "\(mac) closed the connection."
        case .posix(.ETIMEDOUT):
            return "\(mac) did not answer."
        case .posix(.EHOSTUNREACH), .posix(.ENETUNREACH), .posix(.ENETDOWN), .posix(.EHOSTDOWN), .posix(.EADDRNOTAVAIL):
            return "\(mac) cannot be reached on this network."
        case .dns:
            return "\(mac) cannot be found on the local network\(statusNote)."
        case .tls:
            return "The secure connection to \(mac) failed\(statusNote)."
        default:
            return "\(mac) cannot be reached\(statusNote)."
        }
    }
}

/// Local Network access, as the screens that say it is off offer its one fix (spec 9): System Settings, at Local
/// Network.
public enum LocalNetwork {
    /// Whether `sentence` (a listener's, a browser's or a link's) says Local Network access is off for Nítido.
    public static func isOff(_ sentence: String) -> Bool { sentence.contains(NWError.localNetworkOff) }
    /// Privacy and Security, Local Network, in System Settings.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
}
