import Foundation
import Logging
import XcodeMCPProxy

@main
struct XcodeMCPProxyCLI {
    static func main() async {
        ProxyLogging.bootstrap()
        let logger: Logger = ProxyLogging.make("cli")

        do {
            let args = CommandLine.arguments
            let environment = ProcessInfo.processInfo.environment

            if args.contains("-h") || args.contains("--help") {
                print(usage())
                return
            }

            if args.count > 1, args[1] == "url" || args.contains("--print-url") {
                logger.error("url helper mode was removed; configure your HTTP client with a concrete URL (default: http://localhost:8765/mcp).")
                exit(1)
            }

            let serverOnlyFlags: Set<String> = [
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
            if args.contains(where: { serverOnlyFlags.contains($0) }) {
                logger.error("This option is only supported by xcode-mcp-proxy-server (proxy server).")
                logger.error("Run: xcode-mcp-proxy-server --help")
                exit(1)
            }

            // Always run as STDIO adapter.
            // If the caller didn't specify --stdio/--url, add --stdio so CLIParser resolves the upstream via
            // XCODE_MCP_PROXY_ENDPOINT -> discovery -> default (http://localhost:8765/mcp).
            var parseArgs = args

            // Prefer a more intuitive flag name for overriding the upstream.
            // We keep --stdio as a backwards-compatible alias.
            let hasURL = parseArgs.contains("--url") || parseArgs.contains(where: { $0.hasPrefix("--url=") })
            if hasURL && parseArgs.contains("--stdio") {
                throw CLIError.message("Use either --url or --stdio (not both).")
            }
            if hasURL {
                parseArgs = try rewriteURLFlagToStdio(parseArgs)
            }

            if !parseArgs.contains("--stdio") {
                parseArgs.append("--stdio")
            }
            let config = try CLIParser.parse(args: parseArgs, environment: environment)

            guard let upstreamURL = config.stdioUpstreamURL else {
                logger.error("Missing upstream URL (start xcode-mcp-proxy-server).")
                exit(1)
            }

            let url = upstreamURL.absoluteString
            if let source = config.stdioUpstreamSource {
                switch source {
                case .discovery:
                    logger.info(
                        "STDIO upstream resolved from discovery file",
                        metadata: [
                            "url": "\(url)",
                            "path": "\(Discovery.defaultFileURL.path)",
                        ]
                    )
                case .fallback:
                    logger.info(
                        "STDIO upstream fell back to default",
                        metadata: ["url": "\(url)"]
                    )
                case .environment:
                    logger.info(
                        "STDIO upstream resolved from XCODE_MCP_PROXY_ENDPOINT",
                        metadata: ["url": "\(url)"]
                    )
                case .explicit:
                    logger.info(
                        "STDIO upstream resolved from CLI",
                        metadata: ["url": "\(url)"]
                    )
                }
            }

            let adapter = StdioAdapter(
                upstreamURL: upstreamURL,
                requestTimeout: config.requestTimeout
            )
            await adapter.start()
            await adapter.wait()
        } catch let error as CLIError {
            logger.error("\(error.description)")
            logger.error("\(usage())")
            exit(1)
        } catch {
            logger.error("error: \(error)")
            exit(1)
        }
    }

    private static func rewriteURLFlagToStdio(_ args: [String]) throws -> [String] {
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

    private static func usage() -> String {
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
          - Discovery file: \(Discovery.defaultFileURL.path)
        """
    }
}
