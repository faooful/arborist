// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "devspace",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DevspaceCore", targets: ["DevspaceCore"]),
        .executable(name: "devspace", targets: ["devspace"]),
        .executable(name: "DevspaceApp", targets: ["DevspaceApp"]),
    ],
    targets: [
        .target(name: "DevspaceCore"),
        .executableTarget(name: "devspace", dependencies: ["DevspaceCore"]),
        // The app's SwiftUI code is wrapped in `#if os(macOS)`; on Linux it builds a stub.
        .executableTarget(name: "DevspaceApp", dependencies: ["DevspaceCore"]),
        .testTarget(name: "DevspaceCoreTests", dependencies: ["DevspaceCore"]),
    ]
)
