import Foundation
import CryptoKit

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
