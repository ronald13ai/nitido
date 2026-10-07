// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "nitido",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "nitido", targets: ["nitido"]),
    ],
    targets: [
        .target(name: "NitidoCore", swiftSettings: settings),
        .target(name: "NitidoCapture", dependencies: ["NitidoCore"], swiftSettings: settings),
        .target(name: "NitidoCodec", dependencies: ["NitidoCore"], swiftSettings: settings),
        .target(name: "NitidoLink", dependencies: ["NitidoCore"], swiftSettings: settings),
        .target(name: "NitidoUI",
                dependencies: ["NitidoCore", "NitidoCapture", "NitidoCodec", "NitidoLink"],
                resources: [.copy("Fonts")],
                swiftSettings: settings),
        .executableTarget(name: "nitido", dependencies: ["NitidoUI"], swiftSettings: settings),
        .testTarget(name: "NitidoCoreTests", dependencies: ["NitidoCore"], swiftSettings: settings),
        .testTarget(name: "NitidoCaptureTests", dependencies: ["NitidoCapture"], swiftSettings: settings),
        .testTarget(name: "NitidoCodecTests", dependencies: ["NitidoCodec"], swiftSettings: settings),
        .testTarget(name: "NitidoLinkTests", dependencies: ["NitidoLink"], swiftSettings: settings),
        .testTarget(name: "NitidoUITests", dependencies: ["NitidoUI", "NitidoCapture", "NitidoCodec"], swiftSettings: settings),
    ]
)
