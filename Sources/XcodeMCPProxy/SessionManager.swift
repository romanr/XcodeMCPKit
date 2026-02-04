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
    private struct InitPending: @unchecked Sendable {
        let eventLoop: EventLoop
        let promise: EventLoopPromise<ByteBuffer>
        let originalId: Any
    }

    private let lock = NIOLock()
    private let initLock = NIOLock()
    private let eventLoop: EventLoop
    private var sessions: [String: SessionContext] = [:]
    private let idMapper = UpstreamIdMapper()
    private let config: ProxyConfig
    private var initResult: Any?
    private var initPending: [InitPending] = []
    private var initInFlight = false
    private var initTimeout: Scheduled<Void>?
    private var didSendInitialized = false
    private var isShuttingDown = false
    let upstream: UpstreamProcess

    init(config: ProxyConfig, eventLoop: EventLoop) {
        self.config = config
        self.eventLoop = eventLoop
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
        self.upstream.onExit = { [weak self] status in
            self?.handleUpstreamExit(status)
        }
        self.upstream.start()
        if config.eagerInitialize {
            startEagerInitialize()
        }
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

    func hasSession(id: String) -> Bool {
        lock.withLock { sessions[id] != nil }
    }

    func removeSession(id: String) {
        let context = lock.withLock { sessions.removeValue(forKey: id) }
        context?.sseHub.closeAll()
    }

    func shutdown() {
        upstream.stop()
        initLock.withLock {
            isShuttingDown = true
            initInFlight = false
            initTimeout?.cancel()
            initTimeout = nil
            initPending.removeAll()
        }
    }

    func isInitialized() -> Bool {
        initLock.withLock { initResult != nil }
    }

    func registerInitialize(
        originalId: Any,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        var shouldSend = false
        var initRequest: [String: Any]?
        var cachedResult: Any?
        var shuttingDown = false
        var pendingPromise: EventLoopPromise<ByteBuffer>?

        initLock.withLock {
            if isShuttingDown {
                shuttingDown = true
                return
            }
            if let result = initResult {
                cachedResult = result
                return
            }
            let promise = eventLoop.makePromise(of: ByteBuffer.self)
            pendingPromise = promise
            initPending.append(
                InitPending(
                    eventLoop: eventLoop,
                    promise: promise,
                    originalId: originalId
                )
            )
            if !initInFlight {
                initInFlight = true
                shouldSend = true
                initRequest = requestObject
                scheduleInitTimeout()
            }
        }

        if let cachedResult {
            if let buffer = encodeInitializeResponse(originalId: originalId, result: cachedResult) {
                return eventLoop.makeSucceededFuture(buffer)
            }
            return eventLoop.makeFailedFuture(TimeoutError())
        }

        if shuttingDown {
            return eventLoop.makeFailedFuture(TimeoutError())
        }

        if shouldSend, var initRequest {
            let upstreamId = idMapper.assignInitialize()
            initRequest["id"] = upstreamId
            if let data = try? JSONSerialization.data(withJSONObject: initRequest, options: []) {
                upstream.send(data)
            } else {
                failInitPending(error: TimeoutError())
            }
        }

        guard let promise = pendingPromise else {
            return eventLoop.makeFailedFuture(TimeoutError())
        }
        return promise.futureResult
    }

    private func routeUpstreamMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            broadcastToAllSessions(data)
            return
        }

        if var object = json as? [String: Any],
           let upstreamId = upstreamId(from: object["id"]),
           let mapping = idMapper.consume(upstreamId) {
            if mapping.isInitialize {
                handleInitializeResponse(object)
                return
            }
            if let sessionId = mapping.sessionId, let originalId = mapping.originalId {
                object["id"] = originalId
                if let rewritten = try? JSONSerialization.data(withJSONObject: object, options: []) {
                    let target = session(id: sessionId)
                    target.router.handleIncoming(rewritten)
                    return
                }
            }
        }

        if let array = json as? [Any] {
            var sessionId: String?
            var rewrittenAny = false
            var transformed: [Any] = []
            for item in array {
                guard var object = item as? [String: Any],
                      let upstreamId = upstreamId(from: object["id"]),
                      let mapping = idMapper.consume(upstreamId) else {
                    transformed.append(item)
                    continue
                }
                if mapping.isInitialize {
                    handleInitializeResponse(object)
                    continue
                }
                guard let originalId = mapping.originalId else {
                    transformed.append(item)
                    continue
                }
                object["id"] = originalId
                sessionId = sessionId ?? mapping.sessionId
                rewrittenAny = true
                transformed.append(object)
            }
            if rewrittenAny, let sessionId, let rewritten = try? JSONSerialization.data(withJSONObject: transformed, options: []) {
                let target = session(id: sessionId)
                target.router.handleIncoming(rewritten)
                return
            }
        }

        broadcastToAllSessions(data)
    }

    private func handleUpstreamExit(_ status: Int32) {
        var pending: [InitPending] = []
        var shouldEagerInitialize = false

        initLock.withLock {
            if isShuttingDown {
                return
            }
            initResult = nil
            initInFlight = false
            didSendInitialized = false
            initTimeout?.cancel()
            initTimeout = nil
            pending = initPending
            initPending.removeAll()
            shouldEagerInitialize = config.eagerInitialize
        }

        idMapper.reset()

        for item in pending {
            item.eventLoop.execute {
                item.promise.fail(TimeoutError())
            }
        }

        if shouldEagerInitialize {
            startEagerInitialize()
        }
    }

    func assignUpstreamId(sessionId: String, originalId: Any) -> Int64 {
        idMapper.assign(sessionId: sessionId, originalId: originalId, isInitialize: false)
    }

    private func upstreamId(from value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String, let number = Int64(string) {
            return number
        }
        return nil
    }

    private func broadcastToAllSessions(_ data: Data) {
        let snapshot = lock.withLock { Array(self.sessions.values) }
        for session in snapshot {
            session.router.handleIncoming(data)
        }
    }

    private func startEagerInitialize() {
        var shouldSend = false
        initLock.withLock {
            if initResult == nil && !initInFlight {
                initInFlight = true
                shouldSend = true
                scheduleInitTimeout()
            }
        }
        guard shouldSend else { return }

        let upstreamId = idMapper.assignInitialize()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": upstreamId,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": [
                    "name": "xcode-mcp-proxy",
                    "version": "0.0",
                ],
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: request, options: []) {
            upstream.send(data)
        } else {
            failInitPending(error: TimeoutError())
        }
    }

    private func handleInitializeResponse(_ object: [String: Any]) {
        guard let result = object["result"] else {
            failInitPending(error: TimeoutError())
            return
        }

        var pending: [InitPending] = []
        var shouldSendInitialized = false
        initLock.withLock {
            if isShuttingDown {
                return
            }
            if initResult == nil {
                initResult = result
            }
            initInFlight = false
            initTimeout?.cancel()
            initTimeout = nil
            pending = initPending
            initPending.removeAll()
            if !didSendInitialized {
                didSendInitialized = true
                shouldSendInitialized = true
            }
        }

        if shouldSendInitialized {
            sendInitializedNotification()
        }

        for item in pending {
            if let buffer = encodeInitializeResponse(originalId: item.originalId, result: result) {
                item.eventLoop.execute {
                    item.promise.succeed(buffer)
                }
            } else {
                item.eventLoop.execute {
                    item.promise.fail(TimeoutError())
                }
            }
        }
    }

    private func encodeInitializeResponse(originalId: Any, result: Any) -> ByteBuffer? {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalId,
            "result": result,
        ]
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: []) else {
            return nil
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    private func sendInitializedNotification() {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: notification, options: []) {
            upstream.send(data)
        }
    }

    private func scheduleInitTimeout() {
        initTimeout?.cancel()
        initTimeout = eventLoop.scheduleTask(in: .seconds(Int64(config.requestTimeout))) { [weak self] in
            self?.failInitPending(error: TimeoutError())
        }
    }

    private func failInitPending(error: Error) {
        var pending: [InitPending] = []
        initLock.withLock {
            if isShuttingDown {
                return
            }
            initInFlight = false
            initTimeout?.cancel()
            initTimeout = nil
            pending = initPending
            initPending.removeAll()
        }
        for item in pending {
            item.eventLoop.execute {
                item.promise.fail(error)
            }
        }
    }
}

private final class UpstreamIdMapper {
    private let lock = NIOLock()
    private var nextId: Int64 = 1
    private var mapping: [Int64: UpstreamMapping] = [:]

    func assign(sessionId: String, originalId: Any, isInitialize: Bool) -> Int64 {
        lock.withLock {
            let id = nextId
            nextId += 1
            mapping[id] = UpstreamMapping(
                sessionId: sessionId,
                originalId: originalId,
                isInitialize: isInitialize
            )
            return id
        }
    }

    func assignInitialize() -> Int64 {
        lock.withLock {
            let id = nextId
            nextId += 1
            mapping[id] = UpstreamMapping(
                sessionId: nil,
                originalId: nil,
                isInitialize: true
            )
            return id
        }
    }

    func consume(_ upstreamId: Int64) -> UpstreamMapping? {
        lock.withLock {
            mapping.removeValue(forKey: upstreamId)
        }
    }

    func reset() {
        lock.withLock {
            mapping.removeAll()
        }
    }
}

private struct UpstreamMapping {
    let sessionId: String?
    let originalId: Any?
    let isInitialize: Bool
}
