// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LSwitch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LSwitchCore", targets: ["LSwitchCore"]),
        .executable(name: "lswitch", targets: ["LSwitch"])
    ],
    targets: [
        .target(name: "LSwitchCore"),
        .executableTarget(
            name: "LSwitch",
            dependencies: ["LSwitchCore"]
        ),
        .testTarget(
            name: "LSwitchCoreTests",
            dependencies: ["LSwitchCore"]
        )
    ]
)
