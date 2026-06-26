// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sugarbar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Sugarbar", dependencies: ["SugarbarCore"]),
        .target(name: "SugarbarCore"),
        .testTarget(name: "SugarbarCoreTests", dependencies: ["SugarbarCore"]),
    ]
)
