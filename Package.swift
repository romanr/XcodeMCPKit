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
        .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.4.3"),
    ],
    targets: [
        .target(
            name: "XcodeMCPKit",
            dependencies: [
                "XcodeMCPProxy"
            ],
            path: "Sources/XcodeMCPKit",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "Sources/ProxyCore",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyRuntime",
            dependencies: [
                "ProxyCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            path: "Sources/ProxyRuntime",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyFeatureXcode",
            dependencies: [
                "ProxyCore",
                "ProxyRuntime",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Sources/ProxyFeatureXcode",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyHTTPTransport",
            dependencies: [
                "ProxyCore",
                "ProxyRuntime",
                "ProxyFeatureXcode",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Sources/ProxyHTTPTransport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyStdioTransport",
            dependencies: [
                "ProxyCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ProxyStdioTransport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxy",
            dependencies: [
                "ProxyCore",
                "ProxyRuntime",
                "ProxyFeatureXcode",
                "ProxyHTTPTransport",
                "ProxyStdioTransport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyCLI",
            dependencies: [
                "XcodeMCPProxy",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ProxyCLI",
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
                "ProxyCLI"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyServer",
            dependencies: ["ProxyCLI"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyInstall",
            dependencies: ["ProxyCLI"],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyRuntimeTests",
            dependencies: [
                "XcodeMCPProxy",
                "ProxyCore",
                "ProxyRuntime",
                "ProxyFeatureXcode",
                "ProxyHTTPTransport",
                "ProxyStdioTransport",
                "ProxyCLI",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyRuntimeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyHTTPTransportTests",
            dependencies: [
                "XcodeMCPProxy",
                "ProxyCore",
                "ProxyRuntime",
                "ProxyFeatureXcode",
                "ProxyHTTPTransport",
                "ProxyStdioTransport",
                "ProxyCLI",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyHTTPTransportTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyCLITests",
            dependencies: [
                "XcodeMCPProxy",
                "ProxyCore",
                "ProxyRuntime",
                "ProxyFeatureXcode",
                "ProxyHTTPTransport",
                "ProxyStdioTransport",
                "ProxyCLI",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyCLITests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyIntegrationTests",
            dependencies: [
                "XcodeMCPProxy",
                "ProxyCore",
                "ProxyRuntime",
                "ProxyFeatureXcode",
                "ProxyHTTPTransport",
                "ProxyStdioTransport",
                "ProxyCLI",
                "XcodeMCPTestSupport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyIntegrationTests",
            swiftSettings: strictSwiftSettings
        ),
    ]
)
