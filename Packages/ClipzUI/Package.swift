// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipzUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipzUI", targets: ["ClipzUI"]),
    ],
    dependencies: [
        .package(path: "../ClipzCore"),
        .package(path: "../ClipzML"),
    ],
    targets: [
        .target(
            name: "ClipzUI",
            dependencies: [
                .product(name: "ClipzCore", package: "ClipzCore"),
                .product(name: "ClipzML", package: "ClipzML"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "ClipzUITests",
            dependencies: ["ClipzUI"]
        ),
    ]
)
