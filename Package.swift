// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]

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
            name: "XcodeMCPKit",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxyCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxyUpstream",
            dependencies: [
                "XcodeMCPProxyCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxySession",
            dependencies: [
                "XcodeMCPProxyCore",
                "XcodeMCPProxyUpstream",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxyXcodeSupport",
            dependencies: [
                "XcodeMCPProxyCore",
                "XcodeMCPProxyUpstream",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxyTransportHTTP",
            dependencies: [
                "XcodeMCPProxyCore",
                "XcodeMCPProxyUpstream",
                "XcodeMCPProxySession",
                "XcodeMCPProxyXcodeSupport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxy",
            dependencies: [
                "XcodeMCPProxyCore",
                "XcodeMCPProxyUpstream",
                "XcodeMCPProxySession",
                "XcodeMCPProxyXcodeSupport",
                "XcodeMCPProxyTransportHTTP",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxyCommands",
            dependencies: [
                "XcodeMCPProxy",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPTestSupport",
            dependencies: [
                .product(name: "NIO", package: "swift-nio")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyCLI",
            dependencies: [
                "XcodeMCPProxyCommands"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyServer",
            dependencies: ["XcodeMCPProxyCommands"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyInstall",
            dependencies: ["XcodeMCPProxyCommands"],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPKitTests",
            dependencies: [
                "XcodeMCPKit",
                "XcodeMCPProxy",
                "XcodeMCPProxyCore",
                "XcodeMCPProxyUpstream",
                "XcodeMCPProxySession",
                "XcodeMCPProxyTransportHTTP",
                "XcodeMCPProxyXcodeSupport",
                "XcodeMCPProxyCommands",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPProxyTests",
            dependencies: [
                "XcodeMCPProxy",
                "XcodeMCPProxyCore",
                "XcodeMCPProxyUpstream",
                "XcodeMCPProxySession",
                "XcodeMCPProxyTransportHTTP",
                "XcodeMCPProxyXcodeSupport",
                "XcodeMCPProxyCommands",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
    ]
)
