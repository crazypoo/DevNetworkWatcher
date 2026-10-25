// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PTNetworkStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PTNetworkStudio", targets: ["PTNetworkStudio"])],
    targets: [
        .executableTarget(name: "PTNetworkStudio", path: "Sources/PTNetworkStudio", resources: [.copy("Backend")]),
        .testTarget(name: "PTNetworkStudioTests", dependencies: ["PTNetworkStudio"])
    ]
)
