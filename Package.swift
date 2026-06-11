// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeychronBatteryMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "KeychronBatteryMonitor",
            path: "Sources/KeychronBatteryMonitor",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreBluetooth")
            ]
        )
    ]
)
