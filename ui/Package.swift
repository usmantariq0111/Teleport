// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TeleportUI",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "TeleportUI",
            dependencies: [])
    ]
)
