// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sugarbar",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
    products: [
        .library(name: "SugarbarCore", targets: ["SugarbarCore"]),
        .library(name: "SugarbarUI", targets: ["SugarbarUI"]),
    ],
    targets: [
        .target(name: "SugarbarCore"),
        .target(name: "SugarbarUI", dependencies: ["SugarbarCore"]),
        .testTarget(name: "SugarbarCoreTests", dependencies: ["SugarbarCore"]),
    ]
)
