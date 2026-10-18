// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RelayCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "RelayCore", targets: ["RelayCore"])],
    targets: [
        .target(name: "RelayCore", path: "PhotoRelay/Core", resources: [.process("Resources")]),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"], path: "Tests/RelayCoreTests")
    ]
)
