// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UITestBench",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "UITestBenchCore", targets: ["UITestBenchCore"])
    ],
    targets: [
        .target(name: "UITestBenchCore"),
        .testTarget(
            name: "UITestBenchCoreTests",
            dependencies: ["UITestBenchCore"]
        )
    ]
)
