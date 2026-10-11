import Foundation

public enum WireError: Error, Equatable, Sendable {
    case oversized(Int)
    case truncated
    case malformed(type: UInt8)
}

public enum Wire {
    public static let maxPayload = 16 * 1024 * 1024
    public static let headerSize = 5

    public static func encode(_ m: Message) -> Data {
        var w = ByteWriter()
        switch m {
        case .hello(let h):
            w.u16(h.protocolVersion); w.u8(h.role.rawValue); w.string8(h.name)
            w.u16(h.pixelWidth); w.u16(h.pixelHeight); w.f32(h.scale)
        case .videoConfig(let c):
            w.u8(c.codec.rawValue); w.u16(c.width); w.u16(c.height)
            w.u8(UInt8(min(c.parameterSets.count, 255)))
            for ps in c.parameterSets.prefix(255) { w.u16(UInt16(min(ps.count, 65535))); w.bytes(ps.prefix(65535)) }
        case .videoFrame(let f):
            w.u32(f.seq); w.u64(f.captureHostTimeNs); w.u8(f.isKey ? 1 : 0); w.bytes(f.data)
        case .stroke(let s):
            w.u32(s.strokeId); w.u8(s.phase.rawValue); w.u8(s.color.r); w.u8(s.color.g); w.u8(s.color.b)
            w.f32(s.baseWidth); w.u16(UInt16(min(s.points.count, 65535)))
            for p in s.points.prefix(65535) { w.f32(p.x); w.f32(p.y); w.f32(p.pressure); w.u32(p.tMs) }
        case .cursor(let c):
            w.f32(c.x); w.f32(c.y); w.u8(c.visible ? 1 : 0)
        case .ping(let id, let t):
            w.u32(id); w.u64(t)
        case .pong(let id, let o, let r):
            w.u32(id); w.u64(o); w.u64(r)
        case .keyframeRequest, .clear:
            break
        case .undo(let id):
            w.u32(id)
        case .bye(let reason):
            w.u8(reason)
        }
        var out = ByteWriter()
        out.u32(UInt32(w.data.count)); out.u8(m.typeCode); out.bytes(w.data)
        return out.data
    }

    /// Accumulates chunks from a byte stream and yields whole messages. Unknown types are skipped.
    ///
    /// Reads through the buffer with an offset and drops what it has read once per `feed`: copying the rest of the buffer
    /// after every message made one receive of many small messages (a peer sending 200,000 five-byte `clear`s in one
    /// megabyte) cost time quadratic in its size, and stalled the link's queue for seconds.
    public struct Decoder: Sendable {
        private var buffer = Data()
        public init() {}

        public mutating func feed(_ chunk: Data) throws -> [Message] {
            buffer.append(chunk)
            var out: [Message] = []
            var offset = buffer.startIndex
            defer { buffer = offset == buffer.endIndex ? Data() : Data(buffer[offset...]) }
            while buffer.endIndex - offset >= Wire.headerSize {
                var r = ByteReader(buffer[offset..<(offset + Wire.headerSize)])
                let length = Int(try r.u32())
                let type = try r.u8()
                guard length <= Wire.maxPayload else { throw WireError.oversized(length) }
                let total = Wire.headerSize + length
                guard buffer.endIndex - offset >= total else { break }
                let payload = buffer.subdata(in: (offset + Wire.headerSize)..<(offset + total))
                offset += total
                if let m = try Wire.decodePayload(type: type, payload) { out.append(m) }
            }
            return out
        }
    }

    static func decodePayload(type: UInt8, _ payload: Data) throws -> Message? {
        var r = ByteReader(payload)
        do {
            switch type {
            case 1:
                let v = try r.u16()
                guard let role = Role(rawValue: try r.u8()) else { throw WireError.malformed(type: type) }
                let name = try r.string8(); let w = try r.u16(); let h = try r.u16(); let s = try r.f32()
                return .hello(Hello(protocolVersion: v, role: role, name: name, pixelWidth: w, pixelHeight: h, scale: s))
            case 2:
                guard let codec = Codec(rawValue: try r.u8()) else { throw WireError.malformed(type: type) }
                let w = try r.u16(); let h = try r.u16(); let n = Int(try r.u8())
                var sets: [Data] = []
                for _ in 0..<n { let len = Int(try r.u16()); sets.append(try r.bytes(len)) }
                return .videoConfig(VideoConfig(codec: codec, width: w, height: h, parameterSets: sets))
            case 3:
                let seq = try r.u32(); let t = try r.u64(); let key = try r.u8() == 1
                return .videoFrame(VideoFrame(seq: seq, captureHostTimeNs: t, isKey: key, data: r.rest()))
            case 4:
                let id = try r.u32()
                guard let phase = StrokePhase(rawValue: try r.u8()) else { throw WireError.malformed(type: type) }
                let color = RGB(r: try r.u8(), g: try r.u8(), b: try r.u8())
                let base = try r.f32(); let n = Int(try r.u16())
                var pts: [StrokePoint] = []; pts.reserveCapacity(n)
                for _ in 0..<n {
                    let x = try r.f32(); let y = try r.f32(); let p = try r.f32(); let t = try r.u32()
                    pts.append(StrokePoint(x: x, y: y, pressure: p, tMs: t))
                }
                return .stroke(StrokeMessage(strokeId: id, phase: phase, color: color, baseWidth: base, points: pts))
            case 5:
                let x = try r.f32(); let y = try r.f32(); let v = try r.u8() == 1
                return .cursor(Cursor(x: x, y: y, visible: v))
            case 6:
                let id = try r.u32(); let t = try r.u64()
                return .ping(id: id, tNs: t)
            case 7:
                let id = try r.u32(); let o = try r.u64(); let rp = try r.u64()
                return .pong(id: id, originalTNs: o, replyTNs: rp)
            case 8: return .keyframeRequest
            case 9: return .undo(strokeId: try r.u32())
            case 10: return .clear
            case 11: return .bye(reason: try r.u8())
            default: return nil
            }
        } catch ByteError.truncated {
            throw WireError.truncated
        } catch ByteError.malformed {
            throw WireError.malformed(type: type)
        }
    }
}
