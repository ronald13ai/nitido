import XCTest
@testable import NitidoCore

final class PairingTests: XCTestCase {
    struct FixedRNG: RandomNumberGenerator { var v: UInt64; mutating func next() -> UInt64 { v } }

    func testCodeIsFourDigitsZeroPadded() {
        var rng = FixedRNG(v: 42)
        XCTAssertEqual(Pairing.makeCode(using: &rng), "0042")
        for _ in 0..<50 {
            let c = Pairing.makeCode()
            XCTAssertEqual(c.count, 4); XCTAssertTrue(c.allSatisfy(\.isNumber))
        }
    }

    func testKeyIsDeterministicAndSensitiveToCodeAndName() {
        let a = Pairing.presharedKey(code: "0042", sharerName: "Ronald's Mac")
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(a, Pairing.presharedKey(code: "0042", sharerName: "Ronald's Mac"))
        XCTAssertNotEqual(a, Pairing.presharedKey(code: "0043", sharerName: "Ronald's Mac"))
        XCTAssertNotEqual(a, Pairing.presharedKey(code: "0042", sharerName: "Other Mac"))
    }
}
