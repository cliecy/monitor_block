// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MonitorBlock",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MonitorBlockCore",
            targets: ["MonitorBlockCore"]
        ),
        .executable(
            name: "MonitorBlockApp",
            targets: ["MonitorBlockApp"]
        )
    ],
    targets: [
        .target(
            name: "MonitorBlockCore",
            path: "Sources/MonitorBlockCore"
        ),
        .executableTarget(
            name: "MonitorBlockApp",
            dependencies: ["MonitorBlockCore"],
            path: "Sources/MonitorBlockApp"
        ),
        .testTarget(
            name: "MonitorBlockCoreTests",
            dependencies: ["MonitorBlockCore"],
            path: "Tests/MonitorBlockCoreTests"
        )
    ]
)
