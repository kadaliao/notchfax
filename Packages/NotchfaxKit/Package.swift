// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchfaxKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PrintKit", targets: ["PrintKit"]),
        .library(name: "Memories", targets: ["Memories"]),
        .library(name: "PhotoBooth", targets: ["PhotoBooth"]),
        .library(name: "FaxKit", targets: ["FaxKit"]),
    ],
    targets: [
        .target(name: "PrintKit", exclude: ["README.md"]),
        .target(name: "Memories", dependencies: ["PrintKit"]),
        .target(name: "PhotoBooth", dependencies: ["PrintKit"]),
        .target(name: "FaxKit", dependencies: ["PrintKit"]),
        .testTarget(name: "PrintKitTests", dependencies: ["PrintKit"]),
        .testTarget(name: "MemoriesTests", dependencies: ["Memories"]),
        .testTarget(name: "PhotoBoothTests", dependencies: ["PhotoBooth"]),
        .testTarget(name: "FaxKitTests", dependencies: ["FaxKit"]),
    ],
    swiftLanguageModes: [.v6]
)
