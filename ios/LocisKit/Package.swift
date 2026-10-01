// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocisKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "LocisKit", targets: ["LocisKit"])
    ],
    targets: [
        .target(
            name: "LocisKit",
            // The synthetic demo dataset, kept as a directory tree.
            resources: [.copy("Resources/demo")]
        ),
        .testTarget(name: "LocisKitTests", dependencies: ["LocisKit"]),
    ]
)
