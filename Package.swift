// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Burrow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Burrow", targets: ["Burrow"]),
    ],
    targets: [
        .target(name: "BurrowCore"),
        .executableTarget(name: "Burrow", dependencies: ["BurrowCore"]),
        .testTarget(
            name: "BurrowCoreTests",
            dependencies: ["BurrowCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
