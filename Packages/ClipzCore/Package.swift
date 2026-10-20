// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipzCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipzCore", targets: ["ClipzCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "ClipzCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "ClipzCoreTests",
            dependencies: ["ClipzCore"]
        ),
    ]
)
