import Foundation
import Logging
import XcodeMCPProxy

@main
struct XcodeMCPProxyCLI {
    static func main() async {
        ProxyLogging.bootstrap()
        let logger: Logger = ProxyLogging.make("cli")

        do {
            let config = try CLIParser.parse(
                args: CommandLine.arguments,
                environment: ProcessInfo.processInfo.environment
            )
            if let stdioUpstreamURL = config.stdioUpstreamURL {
                let url = stdioUpstreamURL.absoluteString
                if let source = config.stdioUpstreamSource {
                    switch source {
                    case .discovery:
                        logger.warning(
                            "STDIO upstream resolved from discovery file",
                            metadata: [
                                "url": "\(url)",
                                "path": "\(Discovery.defaultFileURL.path)",
                            ]
                        )
                    case .fallback:
                        logger.warning(
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
                    upstreamURL: stdioUpstreamURL,
                    requestTimeout: config.requestTimeout
                )
                await adapter.start()
                await adapter.wait()
            } else {
                let server = ProxyServer(config: config)
                try await server.run()
            }
        } catch let error as CLIError {
            logger.error("\(error.description)")
            if !error.description.contains("Usage:") {
                logger.error("\(CLIParser.usage())")
            }
            exit(1)
        } catch {
            logger.error("error: \(error)")
            exit(1)
        }
    }
}
