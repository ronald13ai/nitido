import Foundation

public let protocolVersion: UInt16 = 1

public enum Role: UInt8, Sendable, Equatable { case share = 1, view = 2 }

/// The `u8 reason` a `bye` carries (spec section 6).
public enum ByeReason {
    /// The session ended: Esc, Back, Stop or quit.
    public static let ended: UInt8 = 0
    /// The two sides speak different protocol versions.
    public static let protocolMismatch: UInt8 = 1
    /// The sharer stopped capturing (a failure, or Stop Sharing in the menu bar) and no longer listens for viewers.
    public static let sharingStopped: UInt8 = 2
    /// Another viewer proved the code and took this one's seat; the sharer is still sharing. A viewer that does not know
    /// it reads it as `ended`.
    public static let replaced: UInt8 = 3
}
public enum Codec: UInt8, Sendable, Equatable { case hevc = 1, h264 = 2 }
public enum StrokePhase: UInt8, Sendable, Equatable { case begin = 1, append = 2, end = 3 }

public struct RGB: Sendable, Equatable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    public static let gold = RGB(r: 0xc9, g: 0xa8, b: 0x6a)
    public static let cream = RGB(r: 0xf3, g: 0xe3, b: 0xba)
}

/// A point of a stroke in normalized picture coordinates (0...1), with time in ms since the stroke began.
public struct StrokePoint: Sendable, Equatable {
    public var x: Float, y: Float, pressure: Float
    public var tMs: UInt32
    public init(x: Float, y: Float, pressure: Float, tMs: UInt32) { self.x = x; self.y = y; self.pressure = pressure; self.tMs = tMs }
}

public struct Hello: Sendable, Equatable {
    public var protocolVersion: UInt16, role: Role, name: String, pixelWidth: UInt16, pixelHeight: UInt16, scale: Float
    public init(protocolVersion: UInt16, role: Role, name: String, pixelWidth: UInt16, pixelHeight: UInt16, scale: Float) {
        self.protocolVersion = protocolVersion; self.role = role; self.name = name
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.scale = scale
    }
}

public struct VideoConfig: Sendable, Equatable {
    public var codec: Codec, width: UInt16, height: UInt16, parameterSets: [Data]
    public init(codec: Codec, width: UInt16, height: UInt16, parameterSets: [Data]) {
        self.codec = codec; self.width = width; self.height = height; self.parameterSets = parameterSets
    }
}

public struct VideoFrame: Sendable, Equatable {
    public var seq: UInt32, captureHostTimeNs: UInt64, isKey: Bool, data: Data
    public init(seq: UInt32, captureHostTimeNs: UInt64, isKey: Bool, data: Data) {
        self.seq = seq; self.captureHostTimeNs = captureHostTimeNs; self.isKey = isKey; self.data = data
    }
}

public struct StrokeMessage: Sendable, Equatable {
    public var strokeId: UInt32, phase: StrokePhase, color: RGB, baseWidth: Float, points: [StrokePoint]
    public init(strokeId: UInt32, phase: StrokePhase, color: RGB, baseWidth: Float, points: [StrokePoint]) {
        self.strokeId = strokeId; self.phase = phase; self.color = color; self.baseWidth = baseWidth; self.points = points
    }
}

public struct Cursor: Sendable, Equatable {
    public var x: Float, y: Float, visible: Bool
    public init(x: Float, y: Float, visible: Bool) { self.x = x; self.y = y; self.visible = visible }
}

public enum Message: Sendable, Equatable {
    case hello(Hello)
    case videoConfig(VideoConfig)
    case videoFrame(VideoFrame)
    case stroke(StrokeMessage)
    case cursor(Cursor)
    case ping(id: UInt32, tNs: UInt64)
    case pong(id: UInt32, originalTNs: UInt64, replyTNs: UInt64)
    case keyframeRequest
    case undo(strokeId: UInt32)
    case clear
    case bye(reason: UInt8)

    public var typeCode: UInt8 {
        switch self {
        case .hello: 1
        case .videoConfig: 2
        case .videoFrame: 3
        case .stroke: 4
        case .cursor: 5
        case .ping: 6
        case .pong: 7
        case .keyframeRequest: 8
        case .undo: 9
        case .clear: 10
        case .bye: 11
        }
    }
}
