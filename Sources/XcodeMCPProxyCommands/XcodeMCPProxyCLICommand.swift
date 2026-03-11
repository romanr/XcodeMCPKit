import Foundation
import Logging
import XcodeMCPProxy

extension StdioAdapter: CLICommandAdapter {}

package struct CLICommandLogSink {
    package var error: (String) -> Void
    package var info: (String, Logger.Metadata) -> Void

    package init(
        error: @escaping (String) -> Void,
        info: @escaping (String, Logger.Metadata) -> Void
    ) {
        self.error = error
        self.info = info
    }
}

package struct CLICommandInvocation {
    package var showHelp = false
    package var usesRemovedURLHelper = false
    package var hasExplicitURL = false
    package var hasStdioFlag = false
    package var serverOnlyFlag: String?
}

package struct XcodeMCPProxyCLICommand {
    package struct Dependencies {
        package var bootstrapLogging: ([String: String]) -> Void
        package var stdout: (String) -> Void
        package var makeLogSink: () -> CLICommandLogSink
        package var makeAdapter: (URL, TimeInterval, FileHandle, FileHandle) -> any CLICommandAdapter
        package var input: FileHandle
        package var output: FileHandle

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            makeLogSink: @escaping () -> CLICommandLogSink,
            makeAdapter: @escaping (URL, TimeInterval, FileHandle, FileHandle) -> any CLICommandAdapter,
            input: FileHandle,
            output: FileHandle
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.makeLogSink = makeLogSink
            self.makeAdapter = makeAdapter
            self.input = input
            self.output = output
        }

        package static var live: Self {
            return Self(
                bootstrapLogging: ProxyLogging.bootstrap,
                stdout: { print($0) },
                makeLogSink: {
                    let logger = ProxyLogging.make("cli")
                    return CLICommandLogSink(
                        error: { logger.error("\($0)") },
                        info: { message, metadata in
                            logger.info("\(message)", metadata: metadata)
                        }
                    )
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
        let logSink = dependencies.makeLogSink()
        let invocation = Self.scanInvocation(args)

        if invocation.showHelp {
            dependencies.stdout(Self.usage())
            return 0
        }

        if invocation.usesRemovedURLHelper {
            logSink.error(
                "url helper mode was removed; configure your HTTP client with a concrete URL (default: http://localhost:8765/mcp)."
            )
            return 1
        }

        if invocation.serverOnlyFlag != nil {
            logSink.error(
                "This option is only supported by xcode-mcp-proxy-server (proxy server)."
            )
            logSink.error("Run: xcode-mcp-proxy-server --help")
            return 1
        }

        do {
            var parseArgs = args
            if invocation.hasExplicitURL && invocation.hasStdioFlag {
                throw CLIError.message("Use either --url or --stdio (not both).")
            }
            if invocation.hasExplicitURL {
                parseArgs = try Self.rewriteURLFlagToStdio(parseArgs)
            }

            if !parseArgs.contains("--stdio") {
                parseArgs.append("--stdio")
            }

            let config = try CLIParser.parse(args: parseArgs, environment: environment)
            guard let upstreamURL = config.stdioUpstreamURL else {
                logSink.error("Missing upstream URL (start xcode-mcp-proxy-server).")
                return 1
            }

            logResolvedUpstream(config: config, upstreamURL: upstreamURL, logSink: logSink)

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
            logSink.error(error.description)
            logSink.error(Self.usage())
            return 1
        } catch {
            logSink.error("error: \(error)")
            return 1
        }
    }
    private func logResolvedUpstream(
        config: ProxyConfig,
        upstreamURL: URL,
        logSink: CLICommandLogSink
    ) {
        let url = upstreamURL.absoluteString
        guard let source = config.stdioUpstreamSource else {
            return
        }

        switch source {
        case .discovery:
            logSink.info(
                "STDIO upstream resolved from discovery file",
                [
                    "url": "\(url)",
                    "path": "\(Discovery.defaultFileURL.path)",
                ]
            )
        case .fallback:
            logSink.info(
                "STDIO upstream fell back to default",
                ["url": "\(url)"]
            )
        case .environment:
            logSink.info(
                "STDIO upstream resolved from XCODE_MCP_PROXY_ENDPOINT",
                ["url": "\(url)"]
            )
        case .explicit:
            logSink.info(
                "STDIO upstream resolved from CLI",
                ["url": "\(url)"]
            )
        }
    }
}
