// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Muses",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Muses", targets: ["Muses"]),
        .executable(name: "MusesWebHomeHelper", targets: ["MusesWebHomeHelper"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Muses",
            dependencies: ["MusesWebHomeProtocol"],
            path: "Muses/Sources/Muses",
            resources: [
                .copy("Resources"),
            ]
        ),
        .target(
            name: "MusesWebHomeProtocol",
            path: "Muses/Sources/MusesWebHomeProtocol"
        ),
        .target(
            name: "MusesWebHomeCore",
            dependencies: ["MusesWebHomeProtocol"],
            path: "Muses/Sources/MusesWebHomeCore"
        ),
        .executableTarget(
            name: "MusesWebHomeHelper",
            dependencies: ["MusesWebHomeProtocol", "MusesWebHomeCore"],
            path: "Muses/Sources/MusesWebHomeHelper"
        ),
        .testTarget(
            name: "MusesTests",
            dependencies: ["Muses", "MusesWebHomeProtocol", "MusesWebHomeCore"],
            path: "Muses/Tests/MusesTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
