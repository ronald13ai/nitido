import Foundation
import CryptoKit

/// Pairing code and the TLS pre-shared key derived from it.
///
/// Security limit (spec section 13): the key is only as strong as the 4-digit code, 10,000 values.
/// The salt (`pskIdentity`) and the info (the sharer name, broadcast over Bonjour) are public, so
/// HKDF adds no secrecy. The link must use an ECDHE_PSK ciphersuite so a recorded handshake cannot
/// be brute-forced offline; an active attacker on the same LAN can still guess the code in real
/// time, so pairing is for trusted networks only. A PAKE or a high-entropy secret is the fix.
public enum Pairing {
    public static let pskIdentity = "nitido-v1"

    public static func makeCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return makeCode(using: &rng)
    }

    public static func makeCode(using rng: inout some RandomNumberGenerator) -> String {
        String(format: "%04d", Int(rng.next() % 10_000))
    }

    /// HKDF-SHA256(ikm: code, salt: "nitido-v1", info: sharer name), 32 bytes.
    public static func presharedKey(code: String, sharerName: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                                         salt: Data(pskIdentity.utf8),
                                         info: Data(sharerName.utf8),
                                         outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}
