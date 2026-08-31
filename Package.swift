// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DymoBridge",
    platforms: [.macOS(.v13)],
    dependencies: [
        // NIOSSL serves TLS from in-memory PEM files — deliberately no
        // Security.framework/keychain involvement, which on modern macOS
        // produces un-dismissable permission dialogs for background daemons.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .executableTarget(
            name: "dymo-bridge",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/DymoBridge"
        )
    ]
)
