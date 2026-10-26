// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WiFiADB",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ADBCore", targets: ["ADBCore"]),
        .executable(name: "WiFiADB", targets: ["WiFiADB"])
    ],
    targets: [
        .target(name: "ADBCore"),
        .executableTarget(name: "WiFiADB", dependencies: ["ADBCore"]),
        .testTarget(name: "ADBCoreTests", dependencies: ["ADBCore"])
    ],
    swiftLanguageModes: [.v5]
)
