// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Loadout",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LoadoutKit", targets: ["LoadoutKit"]),
        .executable(name: "Loadout", targets: ["Loadout"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "LoadoutKit",
            dependencies: ["Yams"],
            path: "Sources/Loadout"
        ),
        .executableTarget(
            name: "Loadout",
            dependencies: ["LoadoutKit"],
            path: "Sources/LoadoutMain"
        ),
        .testTarget(
            name: "LoadoutTests",
            dependencies: ["LoadoutKit"],
            path: "Tests/LoadoutTests"
        ),
    ]
)
