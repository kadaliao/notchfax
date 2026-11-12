// swift-tools-version: 6.0
import PackageDescription

// 宣传片渲染器：用 App 自己的走纸引擎离屏逐帧出画面。只在 debug 下构建（要 @testable import）。
let package = Package(
    name: "NotchfaxFilm",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Packages/NotchfaxKit")],
    targets: [
        .executableTarget(
            name: "film",
            dependencies: [
                .product(name: "PrintKit", package: "NotchfaxKit"),
                .product(name: "Memories", package: "NotchfaxKit"),
                .product(name: "PhotoBooth", package: "NotchfaxKit"),
                .product(name: "FaxKit", package: "NotchfaxKit"),
                .product(name: "RemotePrint", package: "NotchfaxKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
