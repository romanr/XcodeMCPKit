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
