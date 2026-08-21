// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NostePackage",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14)
    ],
    products: [
        .library(name: "NosteCore", targets: ["NosteCore"])
    ],
    targets: [
        .target(name: "NosteCore"),
        .testTarget(name: "NosteCoreTests", dependencies: ["NosteCore"])
    ]
)
