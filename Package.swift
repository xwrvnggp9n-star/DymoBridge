// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DymoBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "dymo-bridge",
            path: "Sources/DymoBridge"
        )
    ]
)
