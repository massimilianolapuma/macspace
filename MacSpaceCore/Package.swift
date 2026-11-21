// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacSpaceCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MacSpaceCore", targets: ["MacSpaceCore"])
    ],
    targets: [
        .target(name: "MacSpaceCore"),
        .testTarget(name: "MacSpaceCoreTests", dependencies: ["MacSpaceCore"])
    ],
    swiftLanguageModes: [.v6]
)
