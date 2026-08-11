// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Muses",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Muses",
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