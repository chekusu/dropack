// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZIPIntegration",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "RelayCore", path: "../.."),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .testTarget(
            name: "ZIPIntegrationTests",
            dependencies: [
                .product(name: "RelayCore", package: "RelayCore"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            resources: [.copy("Fixtures")])
    ]
)
