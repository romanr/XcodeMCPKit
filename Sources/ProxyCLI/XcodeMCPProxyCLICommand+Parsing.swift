import Foundation
import XcodeMCPProxy

extension XcodeMCPProxyCLICommand {
    package static func scanInvocation(_ args: [String]) -> CLICommandInvocation {
        var invocation = CLICommandInvocation()
        var index = 1

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-h", "--help":
                invocation.showHelp = true
                index += 1
            case "url" where index == 1:
                invocation.usesRemovedURLHelper = true
                index += 1
            case "--print-url":
                invocation.usesRemovedURLHelper = true
                index += 1
            case "--url":
                invocation.hasExplicitURL = true
                index += min(2, args.count - index)
            case let value where value.hasPrefix("--url="):
                invocation.hasExplicitURL = true
                index += 1
            case "--stdio":
                invocation.hasStdioFlag = true
                if index + 1 < args.count, !args[index + 1].hasPrefix("-") {
                    index += 2
                } else {
                    index += 1
                }
            case "--request-timeout":
                if index + 1 < args.count, shouldConsumeRequestTimeoutValue(args[index + 1]) {
                    index += 2
                } else {
                    index += 1
                }
            case let flag where Self.serverOnlyFlags.contains(flag):
                if invocation.serverOnlyFlag == nil {
                    invocation.serverOnlyFlag = flag
                }
                if Self.serverOnlyValueFlags.contains(flag) {
                    index += min(2, args.count - index)
                } else {
                    index += 1
                }
            default:
                index += 1
            }
        }

        return invocation
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

    static let serverOnlyFlags: Set<String> = [
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

    static let serverOnlyValueFlags: Set<String> = [
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
    ]

    static func shouldConsumeRequestTimeoutValue(_ token: String) -> Bool {
        if token == "-h" || token == "--help" {
            return true
        }
        if Double(token) != nil {
            return true
        }
        return !token.hasPrefix("-")
    }
}
