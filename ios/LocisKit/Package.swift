// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocisKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "LocisKit", targets: ["LocisKit"])
    ],
    targets: [
        .target(name: "LocisKit"),
        .testTarget(
            name: "LocisKitTests",
            dependencies: ["LocisKit"],
            resources: [.copy("Resources/demo")]
        ),
    ]
)
