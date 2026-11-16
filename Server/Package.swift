// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sugarbar-server",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sugarbar-server", targets: ["sugarbar-server"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "SugarbarServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "sugarbar-server",
            dependencies: ["SugarbarServer"]
        ),
        .testTarget(
            name: "SugarbarServerTests",
            dependencies: [
                "SugarbarServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
