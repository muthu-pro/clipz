// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipzML",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipzML", targets: ["ClipzML"]),
    ],
    dependencies: [
        .package(path: "../ClipzCore"),
    ],
    targets: [
        .target(
            name: "ClipzML",
            dependencies: [
                .product(name: "ClipzCore", package: "ClipzCore"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "ClipzMLTests",
            dependencies: ["ClipzML"]
        ),
    ]
)
