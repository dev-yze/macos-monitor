// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacOSMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacOSMonitorApp", targets: ["MacOSMonitorApp"]),
        .library(name: "MonitorCore", targets: ["MonitorCore"])
    ],
    targets: [
        .executableTarget(
            name: "MacOSMonitorApp",
            dependencies: ["MonitorCore"]
        ),
        .target(
            name: "MonitorCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "MonitorCoreTests",
            dependencies: ["MonitorCore"]
        )
    ]
)
