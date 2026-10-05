// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "brother-airscan-bridge",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CBrotherScan"),
        .target(name: "BridgeCore", dependencies: ["CBrotherScan"]),
        .executableTarget(name: "brother-airscan-bridge", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
    ]
)
