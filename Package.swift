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
            path: "Sources/Muses",
            resources: [
                .copy("Resources"),
            ]
        ),
        .target(
            name: "MusesWebHomeProtocol",
            path: "Sources/MusesWebHomeProtocol"
        ),
        .target(
            name: "MusesWebHomeCore",
            dependencies: ["MusesWebHomeProtocol"],
            path: "Sources/MusesWebHomeCore"
        ),
        .executableTarget(
            name: "MusesWebHomeHelper",
            dependencies: ["MusesWebHomeProtocol", "MusesWebHomeCore"],
            path: "Sources/MusesWebHomeHelper"
        ),
        .testTarget(
            name: "MusesTests",
            dependencies: ["Muses", "MusesWebHomeProtocol", "MusesWebHomeCore"],
            path: "Tests/MusesTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
