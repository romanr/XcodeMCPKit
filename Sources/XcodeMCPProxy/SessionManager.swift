import Foundation
import NIO
import NIOConcurrencyHelpers

final class SessionContext {
    let id: String
    let router: ProxyRouter
    let sseHub: SSEHub
    let upstream: UpstreamProcess

    init(id: String, config: ProxyConfig) {
        self.id = id
        self.sseHub = SSEHub()
        self.router = ProxyRouter(
            requestTimeout: .seconds(Int64(config.requestTimeout)),
            hasActiveSSE: { [weak sseHub] in
                sseHub?.hasClients ?? false
            },
            sendNotification: { [weak sseHub] data in
                sseHub?.broadcast(data)
            }
        )

        var environment = ProcessInfo.processInfo.environment
        if let pid = config.xcodePID {
            environment["MCP_XCODE_PID"] = String(pid)
        }

        if let override = config.upstreamSessionID {
            environment["MCP_XCODE_SESSION_ID"] = override
        } else {
            environment["MCP_XCODE_SESSION_ID"] = id
        }

        let upstreamConfig = UpstreamProcess.Config(
            command: config.upstreamCommand,
            args: config.upstreamArgs,
            environment: environment,
            restartInitialDelay: 1,
            restartMaxDelay: 30
        )
        self.upstream = UpstreamProcess(config: upstreamConfig)
        self.upstream.onMessage = { [weak router] data in
            router?.handleIncoming(data)
        }
        self.upstream.start()
    }
}

final class SessionManager: @unchecked Sendable {
    private let lock = NIOLock()
    private var sessions: [String: SessionContext] = [:]
    private let config: ProxyConfig

    init(config: ProxyConfig) {
        self.config = config
    }

    func session(id: String) -> SessionContext {
        lock.withLock {
            if let existing = sessions[id] {
                return existing
            }
            if config.upstreamSessionID != nil, !sessions.isEmpty {
                print("warning: --session-id is set; multiple clients will share the same upstream session id")
            }
            let context = SessionContext(id: id, config: config)
            sessions[id] = context
            return context
        }
    }
}
