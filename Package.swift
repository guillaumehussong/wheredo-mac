// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wheredo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Wheredo",
            path: "Sources/Wheredo",
            exclude: ["Info.plist", "Entitlements.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker",
                    "Sources/Wheredo/Info.plist"
                ])
            ]
        )
    ]
)
