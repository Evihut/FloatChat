// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FloatChat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FloatChat", path: "Sources/FloatChat")
    ]
)
