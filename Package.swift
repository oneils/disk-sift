// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskSift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiskSift", targets: ["DiskSift"])
    ],
    targets: [
        .target(name: "SiftCore"),
        .executableTarget(name: "DiskSift", dependencies: ["SiftCore"]),
        .testTarget(name: "SiftCoreTests", dependencies: ["SiftCore"]),
        .testTarget(name: "DiskSiftTests", dependencies: ["DiskSift", "SiftCore"]),
    ]
)
