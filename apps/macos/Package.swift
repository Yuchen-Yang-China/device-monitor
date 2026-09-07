// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeviceMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeviceMonitor", targets: ["DeviceMonitor"])
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
            name: "DeviceMonitor",
            dependencies: ["SensorBridge"],
            path: "Sources/DeviceMonitor",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreWLAN")
            ]
        ),
        .testTarget(
            name: "DeviceMonitorTests",
            dependencies: ["DeviceMonitor"],
            path: "Tests/DeviceMonitorTests"
        )
    ]
)
