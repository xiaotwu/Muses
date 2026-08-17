// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Muses",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Muses", targets: ["Muses"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Muses",
            dependencies: [],
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