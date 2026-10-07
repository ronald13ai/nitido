import Foundation
import Network
import dnssd

extension NWError {
    /// The system description, except for the errors a person fixes themselves, which get plain words and the fix.
    var plainDescription: String {
        if case .dns(let code) = self, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            return "Local Network access is off for Nítido. Turn it on in System Settings, Privacy and Security, Local Network."
        }
        return localizedDescription
    }
}
