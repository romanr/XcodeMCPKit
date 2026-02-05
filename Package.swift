// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "XcodeMCPKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "XcodeMCPKit",
            targets: ["XcodeMCPKit"]
        ),
        .executable(
            name: "xcode-mcp-proxy",
            targets: ["XcodeMCPProxyCLI"]
        ),
        .executable(
            name: "xcode-mcp-proxy-server",
            targets: ["XcodeMCPProxyServer"]
        ),
        .executable(
            name: "xcode-mcp-proxy-install",
            targets: ["XcodeMCPProxyInstall"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "XcodeMCPKit"
        ),
        .target(
            name: "XcodeMCPProxy",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "XcodeMCPProxyCLI",
            dependencies: [
                "XcodeMCPProxy",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "XcodeMCPProxyServer",
            dependencies: ["XcodeMCPProxy"]
        ),
        .executableTarget(
            name: "XcodeMCPProxyInstall",
            dependencies: []
        ),
        .testTarget(
            name: "XcodeMCPKitTests",
            dependencies: ["XcodeMCPKit"]
        ),
        .testTarget(
            name: "XcodeMCPProxyTests",
            dependencies: [
                "XcodeMCPProxy",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ]
)
