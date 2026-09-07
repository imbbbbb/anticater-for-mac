// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AntiCater",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AntiCaterCore"),
        // 界面单独成库，可执行目标里只剩 main.swift。
        // 这样做唯一的目的是让 DeviceModel 能被测试引用——executableTarget 是引用不了的。
        .target(name: "AntiCaterUI", dependencies: ["AntiCaterCore"]),
        .executableTarget(name: "anticater-dump", dependencies: ["AntiCaterCore"]),
        .executableTarget(name: "anticater-restore", dependencies: ["AntiCaterCore"]),
        .executableTarget(name: "AntiCaterApp", dependencies: ["AntiCaterUI"]),
        .testTarget(name: "AntiCaterCoreTests", dependencies: ["AntiCaterCore"]),
        .testTarget(name: "AntiCaterUITests", dependencies: ["AntiCaterUI"]),
    ]
)
