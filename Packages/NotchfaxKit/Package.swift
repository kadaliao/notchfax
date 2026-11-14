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
        .library(name: "RemotePrint", targets: ["RemotePrint"]),
        .library(name: "Updater", targets: ["Updater"]),
    ],
    targets: [
        .target(name: "PrintKit", exclude: ["README.md"]),
        .target(name: "Memories", dependencies: ["PrintKit"]),
        .target(name: "PhotoBooth", dependencies: ["PrintKit"]),
        .target(name: "FaxKit", dependencies: ["PrintKit"]),
        .target(name: "RemotePrint", dependencies: ["PrintKit", "FaxKit"]),
        .target(name: "Updater", dependencies: ["PrintKit"]),
        .testTarget(name: "PrintKitTests", dependencies: ["PrintKit"]),
        .testTarget(name: "MemoriesTests", dependencies: ["Memories"]),
        .testTarget(name: "PhotoBoothTests", dependencies: ["PhotoBooth"]),
        .testTarget(name: "FaxKitTests", dependencies: ["FaxKit"]),
        .testTarget(name: "RemotePrintTests", dependencies: ["RemotePrint"]),
        .testTarget(name: "UpdaterTests", dependencies: ["Updater"]),
    ],
    swiftLanguageModes: [.v6]
)
