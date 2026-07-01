// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sugarbar",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SugarbarCore", targets: ["SugarbarCore"]),
    ],
    targets: [
        .target(name: "SugarbarCore"),
        .testTarget(name: "SugarbarCoreTests", dependencies: ["SugarbarCore"]),
    ]
)
