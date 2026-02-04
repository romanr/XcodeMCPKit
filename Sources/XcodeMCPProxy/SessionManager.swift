import Foundation
import NIO
import NIOConcurrencyHelpers

final class SessionContext {
    let id: String
    let router: ProxyRouter
    let sseHub: SSEHub

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
    }
}

final class SessionManager: @unchecked Sendable {
    private let lock = NIOLock()
    private var sessions: [String: SessionContext] = [:]
    private let config: ProxyConfig
    let upstream: UpstreamProcess

    init(config: ProxyConfig) {
        self.config = config
        var environment = ProcessInfo.processInfo.environment
        if let pid = config.xcodePID {
            environment["MCP_XCODE_PID"] = String(pid)
        }
        if let override = config.upstreamSessionID {
            environment["MCP_XCODE_SESSION_ID"] = override
        } else {
            environment["MCP_XCODE_SESSION_ID"] = UUID().uuidString
        }
        let upstreamConfig = UpstreamProcess.Config(
            command: config.upstreamCommand,
            args: config.upstreamArgs,
            environment: environment,
            restartInitialDelay: 1,
            restartMaxDelay: 30
        )
        let process = UpstreamProcess(config: upstreamConfig)
        self.upstream = process
        self.upstream.onMessage = { [weak self] data in
            self?.routeUpstreamMessage(data)
        }
        self.upstream.start()
    }

    func session(id: String) -> SessionContext {
        lock.withLock {
            if let existing = sessions[id] {
                return existing
            }
            let context = SessionContext(id: id, config: config)
            sessions[id] = context
            return context
        }
    }

    private func routeUpstreamMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            broadcastToAllSessions(data)
            return
        }

        if let object = json as? [String: Any] {
            if let idValue = object["id"] as? String, let decoded = IdCodec.decode(idValue) {
                let target = session(id: decoded.sessionId)
                target.router.handleIncoming(data)
                return
            }
            broadcastToAllSessions(data)
            return
        }

        if let array = json as? [Any] {
            for item in array {
                guard let object = item as? [String: Any],
                      let idValue = object["id"] as? String,
                      let decoded = IdCodec.decode(idValue) else { continue }
                let target = session(id: decoded.sessionId)
                target.router.handleIncoming(data)
                return
            }
            broadcastToAllSessions(data)
            return
        }

        broadcastToAllSessions(data)
    }

    private func broadcastToAllSessions(_ data: Data) {
        let snapshot = lock.withLock { Array(self.sessions.values) }
        for session in snapshot {
            session.router.handleIncoming(data)
        }
    }
}
