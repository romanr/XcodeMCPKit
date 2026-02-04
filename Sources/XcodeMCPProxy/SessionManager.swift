import Foundation
import NIO
import NIOConcurrencyHelpers

final class SessionContext: Sendable {
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

final class SessionManager: Sendable {
    private struct InitPending: Sendable {
        let eventLoop: EventLoop
        let promise: EventLoopPromise<ByteBuffer>
        let originalId: RPCId
    }

    private struct SessionState: Sendable {
        var sessions: [String: SessionContext] = [:]
    }

    private struct InitState: Sendable {
        var initResult: JSONValue?
        var initPending: [InitPending] = []
        var initInFlight = false
        var initTimeout: Scheduled<Void>?
        var didSendInitialized = false
        var isShuttingDown = false
    }

    private let sessionsState = NIOLockedValueBox(SessionState())
    private let initState = NIOLockedValueBox(InitState())
    private let upstreamTaskBox = NIOLockedValueBox<Task<Void, Never>?>(nil)
    private let eventLoop: EventLoop
    private let idMapper = UpstreamIdMapper()
    private let config: ProxyConfig
    let upstream: any UpstreamClient

    convenience init(config: ProxyConfig, eventLoop: EventLoop) {
        let upstream = Self.makeDefaultUpstream(config: config)
        self.init(config: config, eventLoop: eventLoop, upstream: upstream)
    }

    init(config: ProxyConfig, eventLoop: EventLoop, upstream: any UpstreamClient) {
        self.config = config
        self.eventLoop = eventLoop
        self.upstream = upstream
        let task = Task { [weak self] in
            guard let self else { return }
            for await event in upstream.events {
                switch event {
                case .message(let data):
                    self.routeUpstreamMessage(data)
                case .exit(let status):
                    self.handleUpstreamExit(status)
                }
            }
        }
        upstreamTaskBox.withLockedValue { taskBox in
            taskBox = task
        }
        Task {
            await upstream.start()
        }
        if config.eagerInitialize {
            startEagerInitialize()
        }
    }

    func session(id: String) -> SessionContext {
        sessionsState.withLockedValue { state in
            if let existing = state.sessions[id] {
                return existing
            }
            let context = SessionContext(id: id, config: config)
            state.sessions[id] = context
            return context
        }
    }

    func hasSession(id: String) -> Bool {
        sessionsState.withLockedValue { state in
            state.sessions[id] != nil
        }
    }

    func removeSession(id: String) {
        let context = sessionsState.withLockedValue { state in
            state.sessions.removeValue(forKey: id)
        }
        context?.sseHub.closeAll()
    }

    func shutdown() {
        let timeout = initState.withLockedValue { state -> Scheduled<Void>? in
            state.isShuttingDown = true
            state.initInFlight = false
            let existing = state.initTimeout
            state.initTimeout = nil
            state.initPending.removeAll()
            return existing
        }
        timeout?.cancel()
        let task = upstreamTaskBox.withLockedValue { taskBox -> Task<Void, Never>? in
            let current = taskBox
            taskBox = nil
            return current
        }
        task?.cancel()
        Task {
            await upstream.stop()
        }
    }

    func isInitialized() -> Bool {
        initState.withLockedValue { $0.initResult != nil }
    }

    func registerInitialize(
        originalId: RPCId,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        var shouldSend = false
        var shouldScheduleTimeout = false
        var initRequest: [String: Any]?
        var cachedResult: JSONValue?
        var shuttingDown = false
        var pendingPromise: EventLoopPromise<ByteBuffer>?

        initState.withLockedValue { state in
            if state.isShuttingDown {
                shuttingDown = true
                return
            }
            if let result = state.initResult {
                cachedResult = result
                return
            }
            let promise = eventLoop.makePromise(of: ByteBuffer.self)
            pendingPromise = promise
            state.initPending.append(
                InitPending(
                    eventLoop: eventLoop,
                    promise: promise,
                    originalId: originalId
                )
            )
            if !state.initInFlight {
                state.initInFlight = true
                shouldSend = true
                initRequest = requestObject
                shouldScheduleTimeout = true
            }
        }

        if shouldScheduleTimeout {
            scheduleInitTimeout()
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
                sendUpstream(data)
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
                object["id"] = originalId.value.foundationObject
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
                object["id"] = originalId.value.foundationObject
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
        let result = initState.withLockedValue { state -> (pending: [InitPending], shouldEagerInitialize: Bool, timeout: Scheduled<Void>?)? in
            if state.isShuttingDown {
                return nil
            }
            state.initResult = nil
            state.initInFlight = false
            state.didSendInitialized = false
            let timeout = state.initTimeout
            state.initTimeout = nil
            let pending = state.initPending
            state.initPending.removeAll()
            return (pending, config.eagerInitialize, timeout)
        }
        guard let result else { return }
        result.timeout?.cancel()
        let pending = result.pending
        let shouldEagerInitialize = result.shouldEagerInitialize

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

    func assignUpstreamId(sessionId: String, originalId: RPCId) -> Int64 {
        idMapper.assign(sessionId: sessionId, originalId: originalId, isInitialize: false)
    }

    func sendUpstream(_ data: Data) {
        Task {
            await upstream.send(data)
        }
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
        let snapshot = sessionsState.withLockedValue { state in
            Array(state.sessions.values)
        }
        for session in snapshot {
            session.router.handleIncoming(data)
        }
    }

    private func startEagerInitialize() {
        var shouldSend = false
        var shouldScheduleTimeout = false
        initState.withLockedValue { state in
            if state.initResult == nil && !state.initInFlight {
                state.initInFlight = true
                shouldSend = true
                shouldScheduleTimeout = true
            }
        }
        if shouldScheduleTimeout {
            scheduleInitTimeout()
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
            sendUpstream(data)
        } else {
            failInitPending(error: TimeoutError())
        }
    }

    private func handleInitializeResponse(_ object: [String: Any]) {
        guard let resultValue = object["result"], let result = JSONValue(any: resultValue) else {
            failInitPending(error: TimeoutError())
            return
        }

        let update = initState.withLockedValue { state -> (pending: [InitPending], shouldSendInitialized: Bool, timeout: Scheduled<Void>?)? in
            if state.isShuttingDown {
                return nil
            }
            if state.initResult == nil {
                state.initResult = result
            }
            state.initInFlight = false
            let timeout = state.initTimeout
            state.initTimeout = nil
            let pending = state.initPending
            state.initPending.removeAll()
            let shouldSendInitialized = !state.didSendInitialized
            if shouldSendInitialized {
                state.didSendInitialized = true
            }
            return (pending, shouldSendInitialized, timeout)
        }
        guard let update else { return }
        update.timeout?.cancel()

        if update.shouldSendInitialized {
            sendInitializedNotification()
        }

        for item in update.pending {
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

    private func encodeInitializeResponse(originalId: RPCId, result: JSONValue) -> ByteBuffer? {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalId.value.foundationObject,
            "result": result.foundationObject,
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
            sendUpstream(data)
        }
    }

    private func scheduleInitTimeout() {
        let timeout = eventLoop.scheduleTask(in: .seconds(Int64(config.requestTimeout))) { [weak self] in
            guard let self else { return }
            self.failInitPending(error: TimeoutError())
        }
        let previous = initState.withLockedValue { state -> Scheduled<Void>? in
            let existing = state.initTimeout
            state.initTimeout = timeout
            return existing
        }
        previous?.cancel()
    }

    private func failInitPending(error: Error) {
        let result = initState.withLockedValue { state -> (pending: [InitPending], timeout: Scheduled<Void>?)? in
            if state.isShuttingDown {
                return nil
            }
            state.initInFlight = false
            let timeout = state.initTimeout
            state.initTimeout = nil
            let pending = state.initPending
            state.initPending.removeAll()
            return (pending, timeout)
        }
        guard let result else { return }
        result.timeout?.cancel()
        for item in result.pending {
            item.eventLoop.execute {
                item.promise.fail(error)
            }
        }
    }
}

private extension SessionManager {
    static func makeDefaultUpstream(config: ProxyConfig) -> UpstreamProcess {
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
        return UpstreamProcess(config: upstreamConfig)
    }
}

private final class UpstreamIdMapper: Sendable {
    private struct State: Sendable {
        var nextId: Int64 = 1
        var mapping: [Int64: UpstreamMapping] = [:]
    }

    private let state = NIOLockedValueBox(State())

    func assign(sessionId: String, originalId: RPCId, isInitialize: Bool) -> Int64 {
        state.withLockedValue { state in
            let id = state.nextId
            state.nextId += 1
            state.mapping[id] = UpstreamMapping(
                sessionId: sessionId,
                originalId: originalId,
                isInitialize: isInitialize
            )
            return id
        }
    }

    func assignInitialize() -> Int64 {
        state.withLockedValue { state in
            let id = state.nextId
            state.nextId += 1
            state.mapping[id] = UpstreamMapping(
                sessionId: nil,
                originalId: nil,
                isInitialize: true
            )
            return id
        }
    }

    func consume(_ upstreamId: Int64) -> UpstreamMapping? {
        state.withLockedValue { state in
            state.mapping.removeValue(forKey: upstreamId)
        }
    }

    func reset() {
        state.withLockedValue { state in
            state.mapping.removeAll()
        }
    }
}

private struct UpstreamMapping: Sendable {
    let sessionId: String?
    let originalId: RPCId?
    let isInitialize: Bool
}
