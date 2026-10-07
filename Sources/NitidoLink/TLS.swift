import Foundation
import Network
import Security
import NitidoCore

public enum LinkTLS {
    /// TCP with no delay and TLS 1.2 ECDHE_PSK (spec section 13: the ephemeral ECDH part stops offline guessing of the code from a recorded handshake).
    public static func parameters(code: String, sharerName: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = Pairing.presharedKey(code: code, sharerName: sharerName)
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(Pairing.pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}
