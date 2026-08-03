// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VinceStat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VinceStat",
            path: "Sources/VinceStat"
        )
    ]
)
