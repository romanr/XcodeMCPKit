import Foundation

public enum ProxyTransport: String, CaseIterable, Sendable {
    case http
    case stdio
    case both
}

public extension ProxyTransport {
    var includesHTTP: Bool {
        self == .http || self == .both
    }

    var includesStdio: Bool {
        self == .stdio || self == .both
    }
}

public struct ProxyConfig: Sendable {
    public var listenHost: String
    public var listenPort: Int
    public var upstreamCommand: String
    public var upstreamArgs: [String]
    public var xcodePID: Int?
    public var upstreamSessionID: String?
    public var maxBodyBytes: Int
    public var requestTimeout: TimeInterval
    public var eagerInitialize: Bool
    public var transport: ProxyTransport

    public init(
        listenHost: String,
        listenPort: Int,
        upstreamCommand: String,
        upstreamArgs: [String],
        xcodePID: Int? = nil,
        upstreamSessionID: String? = nil,
        maxBodyBytes: Int,
        requestTimeout: TimeInterval,
        eagerInitialize: Bool = true,
        transport: ProxyTransport = .both
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.upstreamCommand = upstreamCommand
        self.upstreamArgs = upstreamArgs
        self.xcodePID = xcodePID
        self.upstreamSessionID = upstreamSessionID
        self.maxBodyBytes = maxBodyBytes
        self.requestTimeout = requestTimeout
        self.eagerInitialize = eagerInitialize
        self.transport = transport
    }
}

public enum CLIError: Error, CustomStringConvertible {
    case message(String)

    public var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

public struct CLIParser {
    public static func parse(args: [String], environment: [String: String]) throws -> ProxyConfig {
        var listenHost = "localhost"
        var listenPort = 8765
        var upstreamCommand = "xcrun"
        var upstreamArgs = ["mcpbridge"]
        var xcodePID: Int?
        var upstreamSessionID: String?
        var maxBodyBytes = 1_048_576
        var requestTimeout: TimeInterval = 300
        var eagerInitialize = true
        var transport: ProxyTransport = .both

        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--listen":
                guard index + 1 < args.count else {
                    throw CLIError.message("--listen requires host:port")
                }
                let value = args[index + 1]
                if value.contains(":") {
                    let parsed = try parseListen(value)
                    listenHost = parsed.host
                    listenPort = parsed.port
                } else if let port = Int(value) {
                    listenPort = port
                } else {
                    listenHost = value
                }
                index += 2
            case "--host":
                guard index + 1 < args.count else {
                    throw CLIError.message("--host requires a value")
                }
                listenHost = args[index + 1]
                index += 2
            case "--port":
                guard index + 1 < args.count else {
                    throw CLIError.message("--port requires a value")
                }
                listenPort = Int(args[index + 1]) ?? listenPort
                index += 2
            case "--upstream-command":
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-command requires a value")
                }
                upstreamCommand = args[index + 1]
                index += 2
            case "--upstream-args":
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-args requires a value")
                }
                let value = args[index + 1]
                let parts = value.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
                upstreamArgs = parts.isEmpty ? [] : parts
                index += 2
            case "--upstream-arg":
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-arg requires a value")
                }
                upstreamArgs.append(args[index + 1])
                index += 2
            case "--xcode-pid":
                guard index + 1 < args.count else {
                    throw CLIError.message("--xcode-pid requires a value")
                }
                xcodePID = Int(args[index + 1])
                index += 2
            case "--session-id":
                guard index + 1 < args.count else {
                    throw CLIError.message("--session-id requires a value")
                }
                upstreamSessionID = args[index + 1]
                index += 2
            case "--max-body-bytes":
                guard index + 1 < args.count else {
                    throw CLIError.message("--max-body-bytes requires a value")
                }
                maxBodyBytes = Int(args[index + 1]) ?? maxBodyBytes
                index += 2
            case "--request-timeout":
                guard index + 1 < args.count else {
                    throw CLIError.message("--request-timeout requires seconds")
                }
                requestTimeout = TimeInterval(args[index + 1]) ?? requestTimeout
                index += 2
            case "--lazy-init":
                eagerInitialize = false
                index += 1
            case "--transport":
                guard index + 1 < args.count else {
                    throw CLIError.message("--transport requires a value (http|stdio|both)")
                }
                let value = args[index + 1].lowercased()
                guard let parsed = ProxyTransport(rawValue: value) else {
                    throw CLIError.message("--transport must be one of: http, stdio, both")
                }
                transport = parsed
                index += 2
            case "-h", "--help":
                throw CLIError.message(usage())
            default:
                throw CLIError.message("Unknown argument: \(arg)\n\n\(usage())")
            }
        }

        if xcodePID == nil, let value = environment["MCP_XCODE_PID"], let parsed = Int(value) {
            xcodePID = parsed
        }
        if upstreamSessionID == nil, let value = environment["MCP_XCODE_SESSION_ID"], !value.isEmpty {
            upstreamSessionID = value
        }

        return ProxyConfig(
            listenHost: listenHost,
            listenPort: listenPort,
            upstreamCommand: upstreamCommand,
            upstreamArgs: upstreamArgs,
            xcodePID: xcodePID,
            upstreamSessionID: upstreamSessionID,
            maxBodyBytes: maxBodyBytes,
            requestTimeout: requestTimeout,
            eagerInitialize: eagerInitialize,
            transport: transport
        )
    }

    public static func usage() -> String {
        """
        Usage: xcode-mcp-proxy [options]

        Options:
          --listen host:port         Listen address (default: localhost:8765)
          --host host                Listen host (default: localhost)
          --port port                Listen port (default: 8765)
          --upstream-command cmd     Upstream command (default: xcrun)
          --upstream-args a,b,c      Upstream args (default: mcpbridge)
          --upstream-arg value       Append a single upstream arg
          --xcode-pid pid            Xcode PID (env MCP_XCODE_PID)
          --session-id id            Upstream session id (env MCP_XCODE_SESSION_ID)
          --max-body-bytes n         Max request body size (default: 1048576)
          --request-timeout seconds  Request timeout (default: 300, 0 disables)
          --lazy-init                Initialize upstream only on first client request
          --transport mode           Transport mode: http|stdio|both (default: both)
          -h, --help                 Show help
        """
    }

    private static func parseListen(_ value: String) throws -> (host: String, port: Int) {
        guard let colonIndex = value.lastIndex(of: ":") else {
            throw CLIError.message("--listen expects host:port (got \(value))")
        }
        let hostPart = String(value[..<colonIndex])
        let portPart = String(value[value.index(after: colonIndex)...])
        guard let port = Int(portPart), port > 0 else {
            throw CLIError.message("--listen expects host:port (got \(value))")
        }
        let host = hostPart.isEmpty ? "localhost" : hostPart
        return (host, port)
    }
}
