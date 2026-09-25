// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ballast",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Ballast", path: "Sources/Ballast"),
        .testTarget(name: "BallastTests", dependencies: ["Ballast"], path: "Tests/BallastTests"),
    ]
)
