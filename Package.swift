// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AntiCater",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AntiCaterCore"),
        .executableTarget(name: "anticater-dump", dependencies: ["AntiCaterCore"]),
        .executableTarget(name: "anticater-restore", dependencies: ["AntiCaterCore"]),
        .executableTarget(name: "AntiCaterApp", dependencies: ["AntiCaterCore"]),
        .testTarget(name: "AntiCaterCoreTests", dependencies: ["AntiCaterCore"]),
    ]
)
