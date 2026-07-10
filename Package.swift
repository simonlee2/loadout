// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Loadout",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Loadout",
            dependencies: ["Yams"],
            path: "Sources/Loadout"
        ),
        .testTarget(
            name: "LoadoutTests",
            dependencies: ["Loadout"],
            path: "Tests/LoadoutTests"
        ),
    ]
)
