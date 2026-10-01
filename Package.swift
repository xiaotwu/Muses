// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Muses-Polyhymnia",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Muses", targets: ["Muses"]),
        .executable(name: "MusesWebHomeHelper", targets: ["MusesWebHomeHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Muses",
            dependencies: ["MusesWebHomeProtocol", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Muses",
            resources: [
                .copy("Resources"),
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
