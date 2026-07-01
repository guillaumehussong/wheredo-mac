// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrokBuddy",
    platforms: [.macOS(.v14_2)],
    targets: [
        .executableTarget(
            name: "GrokBuddy",
            path: "Sources/GrokBuddy"
        )
    ]
)
