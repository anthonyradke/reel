// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Reel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Reel", targets: ["Reel"]),
        .executable(name: "reelctl", targets: ["reelctl"]),
    ],
    targets: [
        .target(name: "ReelCore"),
        .executableTarget(
            name: "Reel",
            dependencies: ["ReelCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(name: "reelctl", dependencies: ["ReelCore"]),
        .testTarget(name: "ReelCoreTests", dependencies: ["ReelCore"]),
    ]
)
