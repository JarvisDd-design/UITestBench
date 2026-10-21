// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UITestBench",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "UITestBenchCore", targets: ["UITestBenchCore"]),
        .executable(name: "UITestBenchApp", targets: ["UITestBenchApp"])
    ],
    targets: [
        .target(name: "UITestBenchCore"),
        .executableTarget(
            name: "UITestBenchApp",
            dependencies: ["UITestBenchCore"],
            resources: [
                .copy("Resources/scrcpy-server.jar"),
                .copy("Resources/scrcpy-LICENSE.txt")
            ]
        ),
        .testTarget(
            name: "UITestBenchCoreTests",
            dependencies: ["UITestBenchCore"]
        )
    ]
)
