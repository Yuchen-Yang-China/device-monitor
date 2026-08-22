// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacMonitor", targets: ["MacMonitor"])
    ],
    targets: [
        .target(
            name: "SensorBridge",
            path: "Sources/SensorBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "MacMonitor",
            dependencies: ["SensorBridge"],
            path: "Sources/MacMonitor",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
