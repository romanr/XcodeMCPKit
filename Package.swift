// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "XcodeMCPKit",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "XcodeMCPKit",
            targets: ["XcodeMCPKit"]
        ),
        .executable(
            name: "xcode-mcp-proxy",
            targets: ["XcodeMCPProxy"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "XcodeMCPKit"
        ),
        .executableTarget(
            name: "XcodeMCPProxy",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
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
            ]
        ),
    ]
)
