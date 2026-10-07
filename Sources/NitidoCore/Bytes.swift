import Foundation

/// Big-endian byte writer. Everything on the wire goes through here.
public struct ByteWriter: Sendable {
    public private(set) var data = Data()
    public init() {}
    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xff)) }
    public mutating func u32(_ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((v >> UInt32(shift)) & 0xff)) }
    }
    public mutating func u64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((v >> UInt64(shift)) & 0xff)) }
    }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func bytes(_ d: Data) { data.append(d) }
    /// UTF-8 with a one-byte length prefix. Longer strings are cut to at most 255 bytes,
    /// backing off to the last whole Unicode scalar so the bytes stay valid UTF-8.
    public mutating func string8(_ s: String) {
        var d = Data()
        for scalar in s.unicodeScalars {
            guard d.count + scalar.utf8.count <= 255 else { break }
            d.append(contentsOf: scalar.utf8)
        }
        u8(UInt8(d.count)); data.append(d)
    }
}

public enum ByteError: Error, Equatable, Sendable { case truncated, malformed }

/// Big-endian byte reader over any Data (works on slices with non-zero start index).
public struct ByteReader {
    private let data: Data
    private var offset: Int
    public init(_ data: Data) { self.data = data; self.offset = data.startIndex }
    public var remaining: Int { data.endIndex - offset }
    public var isAtEnd: Bool { remaining == 0 }
    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ByteError.truncated }
        let v = data[offset]; offset += 1; return v
    }
    public mutating func u16() throws -> UInt16 {
        let hi = try u8(); let lo = try u8()
        return (UInt16(hi) << 8) | UInt16(lo)
    }
    public mutating func u32() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 { let b = try u8(); v = (v << 8) | UInt32(b) }
        return v
    }
    public mutating func u64() throws -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<8 { let b = try u8(); v = (v << 8) | UInt64(b) }
        return v
    }
    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    public mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw ByteError.truncated }
        let d = data.subdata(in: offset..<(offset + n)); offset += n; return d
    }
    public mutating func rest() -> Data {
        let d = data.subdata(in: offset..<data.endIndex); offset = data.endIndex; return d
    }
    public mutating func string8() throws -> String {
        let n = Int(try u8())
        let d = try bytes(n)
        guard let s = String(data: d, encoding: .utf8) else { throw ByteError.malformed }
        return s
    }
}
