// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelgeLauncher",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "HelgeLauncher",
            dependencies: ["TOMLKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "HelgeLauncherTests",
            dependencies: ["HelgeLauncher"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
