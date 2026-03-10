import Foundation
import Logging
import XcodeMCPProxy

extension StdioAdapter: CLICommandAdapter {}

package struct XcodeMCPProxyCLICommand {
    package struct Dependencies {
        package var bootstrapLogging: ([String: String]) -> Void
        package var stdout: (String) -> Void
        package var logError: (String) -> Void
        package var logInfo: (String, Logger.Metadata) -> Void
        package var makeAdapter: (URL, TimeInterval, FileHandle, FileHandle) -> any CLICommandAdapter
        package var input: FileHandle
        package var output: FileHandle

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            logError: @escaping (String) -> Void,
            logInfo: @escaping (String, Logger.Metadata) -> Void,
            makeAdapter: @escaping (URL, TimeInterval, FileHandle, FileHandle) -> any CLICommandAdapter,
            input: FileHandle,
            output: FileHandle
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.logError = logError
            self.logInfo = logInfo
            self.makeAdapter = makeAdapter
            self.input = input
            self.output = output
        }

        package static var live: Self {
            let logger = ProxyLogging.make("cli")
            return Self(
                bootstrapLogging: ProxyLogging.bootstrap,
                stdout: { print($0) },
                logError: { logger.error("\($0)") },
                logInfo: { message, metadata in
                    logger.info("\(message)", metadata: metadata)
                },
                makeAdapter: { upstreamURL, requestTimeout, input, output in
                    StdioAdapter(
                        upstreamURL: upstreamURL,
                        requestTimeout: requestTimeout,
                        input: input,
                        output: output
                    )
                },
                input: .standardInput,
                output: .standardOutput
            )
        }
    }

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) async -> Int32 {
        dependencies.bootstrapLogging(environment)

        if args.contains("-h") || args.contains("--help") {
            dependencies.stdout(Self.usage())
            return 0
        }

        if (args.count > 1 && args[1] == "url") || args.contains("--print-url") {
            dependencies.logError(
                "url helper mode was removed; configure your HTTP client with a concrete URL (default: http://localhost:8765/mcp)."
            )
            return 1
        }

        if args.contains(where: { Self.serverOnlyFlags.contains($0) }) {
            dependencies.logError(
                "This option is only supported by xcode-mcp-proxy-server (proxy server)."
            )
            dependencies.logError("Run: xcode-mcp-proxy-server --help")
            return 1
        }

        do {
            var parseArgs = args
            let hasURL =
                parseArgs.contains("--url") || parseArgs.contains(where: { $0.hasPrefix("--url=") })
            if hasURL && parseArgs.contains("--stdio") {
                throw CLIError.message("Use either --url or --stdio (not both).")
            }
            if hasURL {
                parseArgs = try Self.rewriteURLFlagToStdio(parseArgs)
            }

            if !parseArgs.contains("--stdio") {
                parseArgs.append("--stdio")
            }

            let config = try CLIParser.parse(args: parseArgs, environment: environment)
            guard let upstreamURL = config.stdioUpstreamURL else {
                dependencies.logError("Missing upstream URL (start xcode-mcp-proxy-server).")
                return 1
            }

            logResolvedUpstream(config: config, upstreamURL: upstreamURL)

            let adapter = dependencies.makeAdapter(
                upstreamURL,
                config.requestTimeout,
                dependencies.input,
                dependencies.output
            )
            await adapter.start()
            await adapter.wait()
            return 0
        } catch let error as CLIError {
            dependencies.logError(error.description)
            dependencies.logError(Self.usage())
            return 1
        } catch {
            dependencies.logError("error: \(error)")
            return 1
        }
    }

    package static func rewriteURLFlagToStdio(_ args: [String]) throws -> [String] {
        var rewritten: [String] = []
        rewritten.reserveCapacity(args.count + 1)
        var didRewrite = false

        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--url" {
                guard !didRewrite else {
                    throw CLIError.message("--url may only be specified once.")
                }
                guard index + 1 < args.count else {
                    throw CLIError.message("--url requires a value (http/https URL).")
                }
                let value = args[index + 1]
                guard !value.hasPrefix("-") else {
                    throw CLIError.message("--url requires a value (http/https URL).")
                }
                rewritten.append("--stdio")
                rewritten.append(value)
                didRewrite = true
                index += 2
                continue
            }

            if arg.hasPrefix("--url=") {
                guard !didRewrite else {
                    throw CLIError.message("--url may only be specified once.")
                }
                let value = String(arg.dropFirst("--url=".count))
                guard !value.isEmpty else {
                    throw CLIError.message("--url requires a value (http/https URL).")
                }
                rewritten.append("--stdio")
                rewritten.append(value)
                didRewrite = true
                index += 1
                continue
            }

            rewritten.append(arg)
            index += 1
        }

        return rewritten
    }

    package static func usage(discoveryFileURL: URL = Discovery.defaultFileURL) -> String {
        """
        Usage:
          xcode-mcp-proxy [options]

        Description:
          STDIO adapter that forwards MCP traffic to a running xcode-mcp-proxy-server (HTTP/SSE).

        Options:
          --request-timeout seconds  Request timeout (default: 300, 0 disables)
          --url url                  Explicit upstream URL (default: env/discovery/http://localhost:8765/mcp)
          -h, --help                 Show help

        Environment:
          XCODE_MCP_PROXY_ENDPOINT   Upstream proxy URL (overrides discovery)

        Notes:
          - Proxy server: xcode-mcp-proxy-server
          - Discovery file: \(discoveryFileURL.path)
        """
    }

    private static let serverOnlyFlags: Set<String> = [
        "--listen",
        "--host",
        "--port",
        "--max-body-bytes",
        "--upstream-command",
        "--upstream-args",
        "--upstream-arg",
        "--upstream-processes",
        "--xcode-pid",
        "--session-id",
        "--lazy-init",
    ]

    private func logResolvedUpstream(config: ProxyConfig, upstreamURL: URL) {
        let url = upstreamURL.absoluteString
        guard let source = config.stdioUpstreamSource else {
            return
        }

        switch source {
        case .discovery:
            dependencies.logInfo(
                "STDIO upstream resolved from discovery file",
                [
                    "url": "\(url)",
                    "path": "\(Discovery.defaultFileURL.path)",
                ]
            )
        case .fallback:
            dependencies.logInfo(
                "STDIO upstream fell back to default",
                ["url": "\(url)"]
            )
        case .environment:
            dependencies.logInfo(
                "STDIO upstream resolved from XCODE_MCP_PROXY_ENDPOINT",
                ["url": "\(url)"]
            )
        case .explicit:
            dependencies.logInfo(
                "STDIO upstream resolved from CLI",
                ["url": "\(url)"]
            )
        }
    }
}
