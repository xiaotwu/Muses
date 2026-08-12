// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Muses",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Muses", targets: ["Muses"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Muses",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Muses/Sources/Muses",
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "MusesTests",
            dependencies: ["Muses"],
            path: "Muses/Tests/MusesTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)