// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelgeLauncher",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.7.3"),
    ],
    targets: [
        .target(
            name: "Calc",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "HelgeLauncher",
            dependencies: ["TOMLKit", "Calc", .product(name: "Markdown", package: "swift-markdown")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "HelgeLauncherTests",
            dependencies: ["HelgeLauncher"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CalcTests",
            dependencies: ["Calc"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
