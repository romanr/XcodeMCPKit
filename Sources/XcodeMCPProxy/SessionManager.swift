import Foundation
import NIO
import NIOConcurrencyHelpers

final class SessionContext: Sendable {
    let id: String
    let router: ProxyRouter
    let notificationHub: NotificationHub

    init(id: String, config: ProxyConfig) {
        self.id = id
        self.notificationHub = NotificationHub()
        self.router = ProxyRouter(
            requestTimeout: makeRequestTimeout(config.requestTimeout),
            hasActiveClients: { [weak notificationHub] in
                notificationHub?.hasClients ?? false
            },
            sendNotification: { [weak notificationHub] data in
                notificationHub?.broadcast(data)
            }
        )
    }
}

protocol SessionManaging: Sendable {
    func session(id: String) -> SessionContext
    func hasSession(id: String) -> Bool
    func removeSession(id: String)
    func shutdown()
    func isInitialized() -> Bool
    func registerInitialize(
        originalId: RPCId,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer>
    func chooseUpstreamIndex(sessionId: String) -> Int
    func assignUpstreamId(sessionId: String, originalId: RPCId, upstreamIndex: Int) -> Int64
    func sendUpstream(_ data: Data, upstreamIndex: Int)
}

final class SessionManager: Sendable, SessionManaging {
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
        var isShuttingDown = false
        var didWarmSecondary = false
        var primaryInitUpstreamId: Int64?
    }

    private let sessionsState = NIOLockedValueBox(SessionState())
    private let initState = NIOLockedValueBox(InitState())
    private let upstreamTaskBox = NIOLockedValueBox<[Task<Void, Never>]>([])
    private let eventLoop: EventLoop
    private let idMapper: UpstreamIdMapper
    private let config: ProxyConfig
    let upstreams: [any UpstreamClient]

    private struct UpstreamState: Sendable {
        var isInitialized = false
        var initInFlight = false
        var initTimeout: Scheduled<Void>?
        var didSendInitialized = false
        var initUpstreamId: Int64?
    }

    private struct UpstreamPoolState: Sendable {
        var upstreamStates: [UpstreamState] = []
        var nextPick: Int = 0
    }

    private let upstreamState = NIOLockedValueBox(UpstreamPoolState())

    convenience init(config: ProxyConfig, eventLoop: EventLoop) {
        let count = max(1, min(config.upstreamProcessCount, 10))
        let sharedSessionID = config.upstreamSessionID ?? UUID().uuidString
        let upstreams = Self.makeDefaultUpstreams(config: config, sharedSessionID: sharedSessionID, count: count)
        self.init(config: config, eventLoop: eventLoop, upstreams: upstreams)
    }

    init(config: ProxyConfig, eventLoop: EventLoop, upstreams: [any UpstreamClient]) {
        precondition(!upstreams.isEmpty, "upstreams must not be empty")
        self.config = config
        self.eventLoop = eventLoop
        self.upstreams = upstreams
        self.idMapper = UpstreamIdMapper(upstreamCount: upstreams.count)
        upstreamState.withLockedValue { state in
            state.upstreamStates = Array(repeating: UpstreamState(), count: upstreams.count)
            state.nextPick = 0
        }

        var tasks: [Task<Void, Never>] = []
        tasks.reserveCapacity(upstreams.count)
        for (upstreamIndex, upstream) in upstreams.enumerated() {
            let task = Task { [weak self] in
                guard let self else { return }
                for await event in upstream.events {
                    switch event {
                    case .message(let data):
                        self.routeUpstreamMessage(data, upstreamIndex: upstreamIndex)
                    case .exit(let status):
                        self.handleUpstreamExit(status, upstreamIndex: upstreamIndex)
                    }
                }
            }
            tasks.append(task)
            Task {
                await upstream.start()
            }
        }
        upstreamTaskBox.withLockedValue { taskBox in
            taskBox = tasks
        }

        if config.eagerInitialize {
            startEagerInitializePrimary()
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
        context?.notificationHub.closeAll()
    }

    func shutdown() {
        let globalTimeout = initState.withLockedValue { state -> Scheduled<Void>? in
            state.isShuttingDown = true
            state.initInFlight = false
            let existing = state.initTimeout
            state.initTimeout = nil
            state.initPending.removeAll()
            return existing
        }
        globalTimeout?.cancel()

        let upstreamTimeouts = upstreamState.withLockedValue { state -> [Scheduled<Void>?] in
            var timeouts: [Scheduled<Void>?] = []
            timeouts.reserveCapacity(state.upstreamStates.count)
            for index in 0..<state.upstreamStates.count {
                timeouts.append(state.upstreamStates[index].initTimeout)
                state.upstreamStates[index].initTimeout = nil
                state.upstreamStates[index].initInFlight = false
                state.upstreamStates[index].initUpstreamId = nil
            }
            return timeouts
        }
        for timeout in upstreamTimeouts {
            timeout?.cancel()
        }

        let tasks = upstreamTaskBox.withLockedValue { taskBox -> [Task<Void, Never>] in
            let current = taskBox
            taskBox = []
            return current
        }
        for task in tasks {
            task.cancel()
        }
        for upstream in upstreams {
            Task {
                await upstream.stop()
            }
        }
    }

    func isInitialized() -> Bool {
        initState.withLockedValue { $0.initResult != nil }
    }

    func chooseUpstreamIndex(sessionId _: String) -> Int {
        upstreamState.withLockedValue { state in
            let count = state.upstreamStates.count
            guard count > 0 else { return 0 }

            let rawStart = state.nextPick % count
            let start = rawStart >= 0 ? rawStart : rawStart + count
            state.nextPick &+= 1
            for offset in 0..<count {
                let candidate = (start + offset) % count
                if state.upstreamStates[candidate].isInitialized {
                    return candidate
                }
            }
            return 0
        }
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
            let upstreamId = idMapper.assignInitialize(upstreamIndex: 0)
            initState.withLockedValue { state in
                state.primaryInitUpstreamId = upstreamId
            }
            markUpstreamInitInFlight(upstreamIndex: 0, upstreamId: upstreamId)
            initRequest["id"] = upstreamId
            if let data = try? JSONSerialization.data(withJSONObject: initRequest, options: []) {
                sendUpstream(data, upstreamIndex: 0)
            } else {
                failInitPending(error: TimeoutError())
            }
        }

        guard let promise = pendingPromise else {
            return eventLoop.makeFailedFuture(TimeoutError())
        }
        return promise.futureResult
    }

    private func routeUpstreamMessage(_ data: Data, upstreamIndex: Int) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            broadcastToAllSessions(data)
            return
        }

        if var object = json as? [String: Any],
           let upstreamId = upstreamId(from: object["id"]),
           let mapping = idMapper.consume(upstreamIndex: upstreamIndex, upstreamId: upstreamId) {
            if mapping.isInitialize {
                handleInitializeResponse(object, upstreamIndex: upstreamIndex)
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
                      let mapping = idMapper.consume(upstreamIndex: upstreamIndex, upstreamId: upstreamId) else {
                    transformed.append(item)
                    continue
                }
                if mapping.isInitialize {
                    handleInitializeResponse(object, upstreamIndex: upstreamIndex)
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

    private func handleUpstreamExit(_ status: Int32, upstreamIndex: Int) {
        let globalInit = initState.withLockedValue { state -> (pending: [InitPending], timeout: Scheduled<Void>?, hadGlobalInit: Bool, wasInFlight: Bool, primaryInitUpstreamId: Int64?)? in
            if state.isShuttingDown {
                return nil
            }
            let wasInFlight = state.initInFlight
            let hadGlobalInit = state.initResult != nil
            let pending = state.initPending
            let timeout = state.initTimeout
            let primaryId = state.primaryInitUpstreamId

            if upstreamIndex == 0 && wasInFlight {
                state.initInFlight = false
                state.initTimeout = nil
                state.initPending.removeAll()
                state.primaryInitUpstreamId = nil
            }

            return (pending, timeout, hadGlobalInit, wasInFlight, primaryId)
        }
        guard let globalInit else { return }

        if upstreamIndex == 0 && globalInit.wasInFlight {
            globalInit.timeout?.cancel()
            if let upstreamId = globalInit.primaryInitUpstreamId {
                idMapper.remove(upstreamIndex: 0, upstreamId: upstreamId)
            }
            for item in globalInit.pending {
                item.eventLoop.execute {
                    item.promise.fail(TimeoutError())
                }
            }
        }

        clearUpstreamState(upstreamIndex: upstreamIndex)
        idMapper.reset(upstreamIndex: upstreamIndex)

        // If the primary upstream dies after a successful global initialize and there are no
        // remaining initialized upstreams, drop the cached init result. Otherwise, new downstream
        // initialize requests would get an immediate cached response and then fail/hang because
        // there's no initialized upstream to serve subsequent requests.
        let shouldResetGlobalInit: Bool
        if upstreamIndex == 0 && globalInit.hadGlobalInit {
            let anyInitialized = upstreamState.withLockedValue { state in
                state.upstreamStates.contains { $0.isInitialized }
            }
            shouldResetGlobalInit = !anyInitialized
        } else {
            shouldResetGlobalInit = false
        }
        if shouldResetGlobalInit {
            initState.withLockedValue { state in
                state.initResult = nil
                state.didWarmSecondary = false
            }
        }

        if config.eagerInitialize {
            if upstreamIndex == 0 {
                if shouldResetGlobalInit || !globalInit.hadGlobalInit {
                    startEagerInitializePrimary()
                } else {
                    startUpstreamWarmInitialize(upstreamIndex: 0)
                }
            } else if globalInit.hadGlobalInit {
                startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
            }
        }
    }

    func assignUpstreamId(sessionId: String, originalId: RPCId, upstreamIndex: Int) -> Int64 {
        idMapper.assign(upstreamIndex: upstreamIndex, sessionId: sessionId, originalId: originalId, isInitialize: false)
    }

    func sendUpstream(_ data: Data, upstreamIndex: Int) {
        guard upstreamIndex >= 0, upstreamIndex < upstreams.count else {
            return
        }
        Task {
            await upstreams[upstreamIndex].send(data)
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

    private func startEagerInitializePrimary() {
        var shouldSend = false
        var shouldScheduleTimeout = false
        var upstreamId: Int64?
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

        upstreamId = idMapper.assignInitialize(upstreamIndex: 0)
        if let upstreamId {
            initState.withLockedValue { state in
                state.primaryInitUpstreamId = upstreamId
            }
            markUpstreamInitInFlight(upstreamIndex: 0, upstreamId: upstreamId)
        }

        let request = makeInternalInitializeRequest(id: upstreamId ?? 1)
        if let data = try? JSONSerialization.data(withJSONObject: request, options: []) {
            sendUpstream(data, upstreamIndex: 0)
        } else {
            failInitPending(error: TimeoutError())
        }
    }

    private func handleInitializeResponse(_ object: [String: Any], upstreamIndex: Int) {
        guard let resultValue = object["result"], let result = JSONValue(any: resultValue) else {
            if upstreamIndex == 0 {
                failInitPending(error: TimeoutError())
            } else {
                clearUpstreamState(upstreamIndex: upstreamIndex)
            }
            return
        }

        markUpstreamInitialized(upstreamIndex: upstreamIndex)
        sendInitializedNotificationIfNeeded(upstreamIndex: upstreamIndex)

        if upstreamIndex != 0 {
            return
        }

        let update = initState.withLockedValue { state -> (pending: [InitPending], timeout: Scheduled<Void>?, shouldWarmSecondary: Bool)? in
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
            state.primaryInitUpstreamId = nil
            let shouldWarmSecondary = !state.didWarmSecondary
            if shouldWarmSecondary {
                state.didWarmSecondary = true
            }
            return (pending, timeout, shouldWarmSecondary)
        }
        guard let update else { return }
        update.timeout?.cancel()

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

        if update.shouldWarmSecondary {
            warmUpSecondaryUpstreams()
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

    private func sendInitializedNotificationIfNeeded(upstreamIndex: Int) {
        let shouldSend = upstreamState.withLockedValue { state -> Bool in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return false }
            if state.upstreamStates[upstreamIndex].didSendInitialized {
                return false
            }
            state.upstreamStates[upstreamIndex].didSendInitialized = true
            return true
        }
        guard shouldSend else { return }

        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: notification, options: []) {
            sendUpstream(data, upstreamIndex: upstreamIndex)
        }
    }

    private func scheduleInitTimeout() {
        guard let timeoutAmount = makeRequestTimeout(config.requestTimeout) else {
            return
        }
        let timeout = eventLoop.scheduleTask(in: timeoutAmount) { [weak self] in
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
        let result = initState.withLockedValue { state -> (pending: [InitPending], timeout: Scheduled<Void>?, upstreamId: Int64?)? in
            if state.isShuttingDown {
                return nil
            }
            state.initInFlight = false
            let timeout = state.initTimeout
            state.initTimeout = nil
            let pending = state.initPending
            state.initPending.removeAll()
            let upstreamId = state.primaryInitUpstreamId
            state.primaryInitUpstreamId = nil
            return (pending, timeout, upstreamId)
        }
        guard let result else { return }
        result.timeout?.cancel()
        if let upstreamId = result.upstreamId {
            idMapper.remove(upstreamIndex: 0, upstreamId: upstreamId)
        }
        clearUpstreamInitInFlight(upstreamIndex: 0)
        for item in result.pending {
            item.eventLoop.execute {
                item.promise.fail(error)
            }
        }
    }

    private func markUpstreamInitInFlight(upstreamIndex: Int, upstreamId: Int64) {
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initInFlight = true
            state.upstreamStates[upstreamIndex].initUpstreamId = upstreamId
            state.upstreamStates[upstreamIndex].isInitialized = false
        }
    }

    private func clearUpstreamInitInFlight(upstreamIndex: Int) {
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initUpstreamId = nil
            state.upstreamStates[upstreamIndex].initTimeout = nil
        }
    }

    private func clearUpstreamState(upstreamIndex: Int) {
        let timeout = upstreamState.withLockedValue { state -> Scheduled<Void>? in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let timeout = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].isInitialized = false
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].didSendInitialized = false
            state.upstreamStates[upstreamIndex].initUpstreamId = nil
            return timeout
        }
        timeout?.cancel()
    }

    private func markUpstreamInitialized(upstreamIndex: Int) {
        let timeout = upstreamState.withLockedValue { state -> Scheduled<Void>? in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            state.upstreamStates[upstreamIndex].isInitialized = true
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initUpstreamId = nil
            let timeout = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = nil
            return timeout
        }
        timeout?.cancel()
    }

    private func warmUpSecondaryUpstreams() {
        guard upstreams.count > 1 else { return }
        for upstreamIndex in 1..<upstreams.count {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
        }
    }

    private func startUpstreamWarmInitialize(upstreamIndex: Int) {
        var shouldSend = false
        var upstreamId: Int64?
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            if state.upstreamStates[upstreamIndex].isInitialized || state.upstreamStates[upstreamIndex].initInFlight {
                return
            }
            state.upstreamStates[upstreamIndex].initInFlight = true
            shouldSend = true
        }
        guard shouldSend else { return }

        upstreamId = idMapper.assignInitialize(upstreamIndex: upstreamIndex)
        if let upstreamId {
            upstreamState.withLockedValue { state in
                guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
                state.upstreamStates[upstreamIndex].initUpstreamId = upstreamId
            }
            scheduleUpstreamInitTimeout(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
        }

        let request = makeInternalInitializeRequest(id: upstreamId ?? 1)
        if let data = try? JSONSerialization.data(withJSONObject: request, options: []) {
            sendUpstream(data, upstreamIndex: upstreamIndex)
        } else {
            clearUpstreamState(upstreamIndex: upstreamIndex)
        }
    }

    private func scheduleUpstreamInitTimeout(upstreamIndex: Int, upstreamId: Int64) {
        guard let timeoutAmount = makeRequestTimeout(config.requestTimeout) else {
            return
        }
        let timeout = eventLoop.scheduleTask(in: timeoutAmount) { [weak self] in
            guard let self else { return }
            self.handleUpstreamInitTimeout(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
        }
        let previous = upstreamState.withLockedValue { state -> Scheduled<Void>? in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let existing = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = timeout
            return existing
        }
        previous?.cancel()
    }

    private func handleUpstreamInitTimeout(upstreamIndex: Int, upstreamId: Int64) {
        let shouldClear = upstreamState.withLockedValue { state -> Bool in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return false }
            guard state.upstreamStates[upstreamIndex].initUpstreamId == upstreamId else { return false }
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].isInitialized = false
            state.upstreamStates[upstreamIndex].initUpstreamId = nil
            return true
        }
        guard shouldClear else { return }
        idMapper.remove(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
    }

    private func makeInternalInitializeRequest(id: Int64) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
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
    }
}

private func makeRequestTimeout(_ seconds: TimeInterval) -> TimeAmount? {
    guard seconds > 0 else { return nil }
    let nanos = max(1, Int64(seconds * 1_000_000_000))
    return .nanoseconds(nanos)
}

private extension SessionManager {
    static func makeDefaultUpstreams(
        config: ProxyConfig,
        sharedSessionID: String,
        count: Int
    ) -> [UpstreamProcess] {
        var environment = ProcessInfo.processInfo.environment
        if let pid = config.xcodePID {
            environment["MCP_XCODE_PID"] = String(pid)
        }
        environment["MCP_XCODE_SESSION_ID"] = sharedSessionID
        let upstreamConfig = UpstreamProcess.Config(
            command: config.upstreamCommand,
            args: config.upstreamArgs,
            environment: environment,
            restartInitialDelay: 1,
            restartMaxDelay: 30
        )
        if count <= 1 {
            return [UpstreamProcess(config: upstreamConfig)]
        }
        var upstreams: [UpstreamProcess] = []
        upstreams.reserveCapacity(count)
        for _ in 0..<count {
            upstreams.append(UpstreamProcess(config: upstreamConfig))
        }
        return upstreams
    }
}

private final class UpstreamIdMapper: Sendable {
    private struct State: Sendable {
        var nextId: Int64 = 1
        var mappingsByUpstream: [[Int64: UpstreamMapping]] = []
    }

    private let state = NIOLockedValueBox(State())

    init(upstreamCount: Int) {
        state.withLockedValue { state in
            state.mappingsByUpstream = Array(repeating: [:], count: upstreamCount)
        }
    }

    func assign(upstreamIndex: Int, sessionId: String, originalId: RPCId, isInitialize: Bool) -> Int64 {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return 0 }
            let id = state.nextId
            state.nextId += 1
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamMapping(
                sessionId: sessionId,
                originalId: originalId,
                isInitialize: isInitialize
            )
            return id
        }
    }

    func assignInitialize(upstreamIndex: Int) -> Int64 {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return 0 }
            let id = state.nextId
            state.nextId += 1
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamMapping(
                sessionId: nil,
                originalId: nil,
                isInitialize: true
            )
            return id
        }
    }

    func consume(upstreamIndex: Int, upstreamId: Int64) -> UpstreamMapping? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return nil }
            return state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamId)
        }
    }

    func remove(upstreamIndex: Int, upstreamId: Int64) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return }
            state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamId)
        }
    }

    func reset(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return }
            state.mappingsByUpstream[upstreamIndex].removeAll()
        }
    }
}

private struct UpstreamMapping: Sendable {
    let sessionId: String?
    let originalId: RPCId?
    let isInitialize: Bool
}
