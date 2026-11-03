// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "arborist",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ArboristCore", targets: ["ArboristCore"]),
        .executable(name: "arborist", targets: ["arborist"]),
        .executable(name: "ArboristApp", targets: ["ArboristApp"]),
    ],
    targets: [
        .target(name: "ArboristCore"),
        .executableTarget(name: "arborist", dependencies: ["ArboristCore"]),
        // The app's SwiftUI code is wrapped in `#if os(macOS)`; on Linux it builds a stub.
        .executableTarget(name: "ArboristApp", dependencies: ["ArboristCore"]),
        .testTarget(name: "ArboristCoreTests", dependencies: ["ArboristCore"]),
    ]
)
