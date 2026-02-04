import Foundation
import Logging
import NIOConcurrencyHelpers

public enum ProxyLogging {
    private static let bootstrapState = NIOLockedValueBox(false)
    private static let labelPrefix = "XcodeMCPProxy"

    /// Call from the host application to opt into StreamLogHandler-based logging.
    /// Do not call this if swift-log is already bootstrapped elsewhere.
    public static func bootstrap(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let shouldBootstrap = bootstrapState.withLockedValue { state in
            if state {
                return false
            }
            state = true
            return true
        }
        guard shouldBootstrap else { return }

        let level = parseLogLevel(environment["MCP_LOG_LEVEL"])
            ?? parseLogLevel(environment["LOG_LEVEL"])
            ?? .info

        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
    }

    /// Creates a logger without bootstrapping swift-log.
    /// The host application may call `bootstrap()` explicitly if desired.
    public static func make(_ name: String) -> Logger {
        return Logger(label: "\(labelPrefix).\(name)")
    }

    private static func parseLogLevel(_ value: String?) -> Logger.Level? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "trace":
            return .trace
        case "debug":
            return .debug
        case "info":
            return .info
        case "notice":
            return .notice
        case "warn", "warning":
            return .warning
        case "error":
            return .error
        case "critical", "fatal":
            return .critical
        default:
            return nil
        }
    }
}
