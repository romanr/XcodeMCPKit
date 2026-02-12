import Foundation
import Logging
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
    func cachedToolsListResult() -> JSONValue?
    func setCachedToolsListResult(_ result: JSONValue)
    func refreshToolsListIfNeeded()
    func registerInitialize(
        originalId: RPCId,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer>
    func chooseUpstreamIndex(sessionId: String, shouldPin: Bool) -> Int
    func assignUpstreamId(sessionId: String, originalId: RPCId, upstreamIndex: Int) -> Int64
    func sendUpstream(_ data: Data, upstreamIndex: Int)
}

final class SessionManager: Sendable, SessionManaging {
    private struct InitPending: Sendable {
        let eventLoop: EventLoop
        let promise: EventLoopPromise<ByteBuffer>
        let originalId: RPCId
    }

    private struct ToolsListState: Sendable {
        var cachedResult: JSONValue?
        // Used for both the post-initialize warmup and stale-while-revalidate refreshes triggered
        // by HTTP cache hits.
        var warmupInFlight = false
        var internalSessionId: String?
    }

    private struct SessionState: Sendable {
        struct SessionRecord: Sendable {
            let context: SessionContext
            var pinnedUpstreamIndex: Int?
        }

        var sessions: [String: SessionRecord] = [:]
    }

    private struct InitState: Sendable {
        var initResult: JSONValue?
        var initPending: [InitPending] = []
        var initInFlight = false
        var initTimeout: Scheduled<Void>?
        var isShuttingDown = false
        var didWarmSecondary = false
        var primaryInitUpstreamId: Int64?
        // If we drop the cached global init result while the primary is already performing a warm init,
        // retry the eager/global init once that warm init finishes unsuccessfully (error/timeout).
        var shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
    }

    private let sessionsState = NIOLockedValueBox(SessionState())
    private let initState = NIOLockedValueBox(InitState())
    private let upstreamTaskBox = NIOLockedValueBox<[Task<Void, Never>]>([])
    private let eventLoop: EventLoop
    private let idMapper: UpstreamIdMapper
    private let config: ProxyConfig
    private let logger: Logger = ProxyLogging.make("session")
    let upstreams: [any UpstreamClient]
    private let toolsListState = NIOLockedValueBox(ToolsListState())

    private struct UpstreamState: Sendable {
        var isInitialized = false
        var initInFlight = false
        var initTimeout: Scheduled<Void>?
        var didSendInitialized = false
        var initUpstreamId: Int64?
        var unhealthyUntilUptimeNs: UInt64?
        var consecutiveToolsListFailures: Int = 0
        var lastToolsListSuccessUptimeNs: UInt64?
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
                return existing.context
            }
            let context = SessionContext(id: id, config: config)
            state.sessions[id] = SessionState.SessionRecord(context: context, pinnedUpstreamIndex: nil)
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
            state.sessions.removeValue(forKey: id)?.context
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

    func cachedToolsListResult() -> JSONValue? {
        toolsListState.withLockedValue { state in
            return state.cachedResult
        }
    }

    func setCachedToolsListResult(_ result: JSONValue) {
        guard isValidToolsListResult(result) else { return }
        toolsListState.withLockedValue { state in
            state.cachedResult = result
        }
    }

    func refreshToolsListIfNeeded() {
        guard config.prewarmToolsList else { return }
        guard isInitialized() else { return }

        let shouldStart = toolsListState.withLockedValue { state -> Bool in
            if state.warmupInFlight {
                return false
            }
            state.warmupInFlight = true
            return true
        }
        guard shouldStart else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.refreshToolsList()
        }
    }

    func chooseUpstreamIndex(sessionId: String, shouldPin: Bool) -> Int {
        // If we already pinned this session to an initialized upstream, always stick to it.
        // This reduces cross-talk between multiple concurrent clients sharing the same proxy.
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        var pinned = sessionsState.withLockedValue { state in
            state.sessions[sessionId]?.pinnedUpstreamIndex
        }
        if let pinnedIndex = pinned {
            let isUsable = upstreamState.withLockedValue { state in
                guard pinnedIndex >= 0, pinnedIndex < state.upstreamStates.count else { return false }
                if let until = state.upstreamStates[pinnedIndex].unhealthyUntilUptimeNs, until <= nowUptimeNs {
                    state.upstreamStates[pinnedIndex].unhealthyUntilUptimeNs = nil
                }
                let upstream = state.upstreamStates[pinnedIndex]
                return upstream.isInitialized && upstream.unhealthyUntilUptimeNs == nil
            }
            if isUsable {
                return pinnedIndex
            }

            // Upstream is no longer usable; clear the pin so we can re-pick.
            sessionsState.withLockedValue { state in
                state.sessions[sessionId]?.pinnedUpstreamIndex = nil
            }
            pinned = nil
        }

        let chosen = upstreamState.withLockedValue { state -> (index: Int, isHealthy: Bool) in
            let count = state.upstreamStates.count
            guard count > 0 else { return (0, true) }

            let rawStart = state.nextPick % count
            let start = rawStart >= 0 ? rawStart : rawStart + count
            state.nextPick &+= 1

            // Prefer initialized and healthy upstreams.
            for offset in 0..<count {
                let candidate = (start + offset) % count
                if !state.upstreamStates[candidate].isInitialized {
                    continue
                }
                if let until = state.upstreamStates[candidate].unhealthyUntilUptimeNs, until <= nowUptimeNs {
                    state.upstreamStates[candidate].unhealthyUntilUptimeNs = nil
                }
                if state.upstreamStates[candidate].unhealthyUntilUptimeNs == nil {
                    return (candidate, true)
                }
            }

            // Fall back to any initialized upstream, even if temporarily unhealthy.
            for offset in 0..<count {
                let candidate = (start + offset) % count
                if !state.upstreamStates[candidate].isInitialized {
                    continue
                }
                if let until = state.upstreamStates[candidate].unhealthyUntilUptimeNs, until <= nowUptimeNs {
                    state.upstreamStates[candidate].unhealthyUntilUptimeNs = nil
                }
                let healthy = state.upstreamStates[candidate].unhealthyUntilUptimeNs == nil
                return (candidate, healthy)
            }

            return (0, true)
        }

        // Only persist the pin when asked. We typically pin on the first non-initialize JSON-RPC request
        // (method + id), not on notifications.
        if pinned == nil, shouldPin, chosen.isHealthy {
            sessionsState.withLockedValue { state in
                state.sessions[sessionId]?.pinnedUpstreamIndex = chosen.index
            }
        }

        return chosen.index
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
            routeUnmappedUpstreamMessage(data, upstreamIndex: upstreamIndex)
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

        routeUnmappedUpstreamMessage(data, upstreamIndex: upstreamIndex)
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

        // Any sessions pinned to this upstream can no longer rely on it. Clear their pin so the next
        // request will re-pick a live upstream.
        let clearedPins = sessionsState.withLockedValue { state -> Int in
            let keys = Array(state.sessions.keys)
            var cleared = 0
            for key in keys {
                if state.sessions[key]?.pinnedUpstreamIndex == upstreamIndex {
                    state.sessions[key]?.pinnedUpstreamIndex = nil
                    cleared += 1
                }
            }
            return cleared
        }
        if clearedPins > 0 {
            logger.debug("Cleared pinned sessions for exited upstream", metadata: ["upstream": .string("\(upstreamIndex)"), "cleared": .string("\(clearedPins)")])
        }

        // If an upstream dies after a successful global initialize and there are no remaining
        // initialized upstreams, drop the cached init result. Otherwise, new downstream initialize
        // requests would get an immediate cached response and then fail/hang because there's no
        // initialized upstream to serve subsequent requests.
        let shouldResetGlobalInit: Bool
        if globalInit.hadGlobalInit {
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
                if shouldResetGlobalInit {
                    // When the last initialized upstream exits, we drop the cached init result.
                    // Ensure the primary/global initialize path is re-run so the proxy becomes usable
                    // again without requiring a downstream initialize retry.
                    let primaryInitInFlight = upstreamState.withLockedValue { state in
                        guard !state.upstreamStates.isEmpty else { return false }
                        return state.upstreamStates[0].initInFlight
                    }
                    if primaryInitInFlight {
                        initState.withLockedValue { state in
                            state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure = true
                        }
                    } else {
                        initState.withLockedValue { state in
                            state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
                        }
                        startEagerInitializePrimary()
                    }
                }
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

    private func isServerInitiatedMessage(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object["method"] is String
        }
        if let array = value as? [Any] {
            return array.contains { item in
                guard let object = item as? [String: Any] else { return false }
                return object["method"] is String
            }
        }
        return false
    }

    private func routeUnmappedUpstreamMessage(_ data: Data, upstreamIndex: Int) {
        // We have no id-based mapping for this upstream message, so we can't unambiguously route it to a
        // single session. To reduce cross-talk across multiple concurrent agents, only deliver it to
        // sessions pinned to the same upstream. If no session is pinned to this upstream yet, still
        // deliver server-initiated notifications/requests to unpinned sessions so they don't miss
        // pre-pin messages.
        let (pinnedTargets, unpinnedTargets) = sessionsState.withLockedValue { state -> ([SessionContext], [SessionContext]) in
            var pinned: [SessionContext] = []
            var unpinned: [SessionContext] = []
            pinned.reserveCapacity(state.sessions.count)
            unpinned.reserveCapacity(state.sessions.count)
            for record in state.sessions.values {
                if record.pinnedUpstreamIndex == upstreamIndex {
                    pinned.append(record.context)
                } else if record.pinnedUpstreamIndex == nil {
                    unpinned.append(record.context)
                }
            }
            return (pinned, unpinned)
        }

        if !pinnedTargets.isEmpty {
            for session in pinnedTargets {
                session.router.handleIncoming(data)
            }
            return
        }

        if let any = try? JSONSerialization.jsonObject(with: data, options: []),
           isServerInitiatedMessage(any),
           !unpinnedTargets.isEmpty {
            logger.debug(
                "Routing unmapped upstream message to unpinned sessions",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "bytes": .string("\(data.count)"),
                    "targets": .string("\(unpinnedTargets.count)"),
                ]
            )
            for session in unpinnedTargets {
                session.router.handleIncoming(data)
            }
            return
        }

        logger.debug(
            "Dropping unmapped upstream message (no pinned sessions)",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "bytes": .string("\(data.count)"),
            ]
        )
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
            state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
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

        // Warm tools/list once so HTTP clients (Codex startup) don't pay the first-hit penalty.
        refreshToolsListIfNeeded()
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
        let result = initState.withLockedValue { state -> (pending: [InitPending], timeout: Scheduled<Void>?, upstreamId: Int64?, shouldRetryEagerInit: Bool)? in
            if state.isShuttingDown {
                return nil
            }
            let shouldRetryEagerInit = state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure && state.initResult == nil
            if shouldRetryEagerInit {
                state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
            }
            state.initInFlight = false
            let timeout = state.initTimeout
            state.initTimeout = nil
            let pending = state.initPending
            state.initPending.removeAll()
            let upstreamId = state.primaryInitUpstreamId
            state.primaryInitUpstreamId = nil
            return (pending, timeout, upstreamId, shouldRetryEagerInit)
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

        if result.shouldRetryEagerInit, config.eagerInitialize {
            startEagerInitializePrimary()
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
            state.upstreamStates[upstreamIndex].unhealthyUntilUptimeNs = nil
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures = 0
            state.upstreamStates[upstreamIndex].lastToolsListSuccessUptimeNs = nil
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

    private func toolsListInternalSessionId() -> String {
        if let existing = toolsListState.withLockedValue({ $0.internalSessionId }) {
            return existing
        }

        // Clients can provide arbitrary Mcp-Session-Id values. Use a UUID-backed internal ID
        // and ensure it doesn't match any active session so warmup can't evict real client state.
        var candidate: String
        repeat {
            candidate = "__tools_list_warmup__:" + UUID().uuidString
        } while hasSession(id: candidate)

        return toolsListState.withLockedValue { state in
            if let existing = state.internalSessionId {
                return existing
            }
            state.internalSessionId = candidate
            return candidate
        }
    }

    private func clearPinnedSessions(forUpstreamIndex upstreamIndex: Int) -> Int {
        sessionsState.withLockedValue { state -> Int in
            let keys = Array(state.sessions.keys)
            var cleared = 0
            for key in keys {
                if state.sessions[key]?.pinnedUpstreamIndex == upstreamIndex {
                    state.sessions[key]?.pinnedUpstreamIndex = nil
                    cleared += 1
                }
            }
            return cleared
        }
    }

    private func markToolsListRefreshSucceeded(upstreamIndex: Int, nowUptimeNs: UInt64) {
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].unhealthyUntilUptimeNs = nil
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures = 0
            state.upstreamStates[upstreamIndex].lastToolsListSuccessUptimeNs = nowUptimeNs
        }
    }

    private func markToolsListRefreshFailed(upstreamIndex: Int, nowUptimeNs: UInt64, reason: String) {
        let quarantineNs: UInt64 = 30 * 1_000_000_000
        let quarantineUntil = nowUptimeNs &+ quarantineNs

        var failures = 0
        var shouldRestart = false
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].unhealthyUntilUptimeNs = quarantineUntil
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures += 1
            failures = state.upstreamStates[upstreamIndex].consecutiveToolsListFailures
            shouldRestart = failures >= 3
            if shouldRestart {
                // Reset so we don't spam restarts while the process is still terminating.
                state.upstreamStates[upstreamIndex].consecutiveToolsListFailures = 0
            }
        }

        let clearedPins = clearPinnedSessions(forUpstreamIndex: upstreamIndex)
        logger.debug(
            "tools/list refresh failed; quarantining upstream",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "reason": .string(reason),
                "failures": .string("\(failures)"),
                "quarantine_until_uptime_ns": .string("\(quarantineUntil)"),
                "cleared_pins": .string("\(clearedPins)"),
            ]
        )

        guard shouldRestart, upstreamIndex >= 0, upstreamIndex < upstreams.count else { return }
        guard let process = upstreams[upstreamIndex] as? UpstreamProcess else { return }
        logger.debug(
            "Requesting upstream restart due to consecutive tools/list failures",
            metadata: ["upstream": .string("\(upstreamIndex)")]
        )
        Task {
            await process.requestRestart()
        }
    }

    private func refreshToolsList() async {
        defer {
            toolsListState.withLockedValue { $0.warmupInFlight = false }
        }

        let refreshTimeout: TimeAmount = .seconds(5)
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        let internalSessionId = toolsListInternalSessionId()
        _ = session(id: internalSessionId)

        let upstreamIndex = chooseUpstreamIndex(sessionId: internalSessionId, shouldPin: false)
        guard upstreamIndex >= 0, upstreamIndex < upstreams.count else {
            logger.debug("tools/list refresh: invalid upstream index", metadata: ["upstream": .string("\(upstreamIndex)")])
            return
        }

        let originalId = RPCId(any: NSNumber(value: 1))!
        let refreshSession = session(id: internalSessionId)
        let future = refreshSession.router.registerRequest(
            idKey: originalId.key,
            on: eventLoop,
            timeout: refreshTimeout
        )
        let upstreamId = assignUpstreamId(
            sessionId: internalSessionId,
            originalId: originalId,
            upstreamIndex: upstreamIndex
        )

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": upstreamId,
            "method": "tools/list",
        ]
        guard JSONSerialization.isValidJSONObject(request),
              let requestData = try? JSONSerialization.data(withJSONObject: request, options: []) else {
            markToolsListRefreshFailed(upstreamIndex: upstreamIndex, nowUptimeNs: nowUptimeNs, reason: "encode_request_failed")
            return
        }

        logger.debug(
            "tools/list refresh started",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "timeout": .string("\(refreshTimeout.nanoseconds)ns"),
            ]
        )
        sendUpstream(requestData, upstreamIndex: upstreamIndex)

        do {
            var buffer = try await future.get()
            guard let responseData = buffer.readData(length: buffer.readableBytes),
                  let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any],
                  let resultAny = response["result"],
                  let result = JSONValue(any: resultAny),
                  isValidToolsListResult(result) else {
                markToolsListRefreshFailed(upstreamIndex: upstreamIndex, nowUptimeNs: nowUptimeNs, reason: "invalid_response")
                return
            }

            markToolsListRefreshSucceeded(upstreamIndex: upstreamIndex, nowUptimeNs: nowUptimeNs)
            setCachedToolsListResult(result)
            logger.debug(
                "tools/list refresh succeeded",
                metadata: ["upstream": .string("\(upstreamIndex)"), "bytes": .string("\(responseData.count)")]
            )
        } catch {
            markToolsListRefreshFailed(upstreamIndex: upstreamIndex, nowUptimeNs: nowUptimeNs, reason: "timeout")
        }
    }

    private func isValidToolsListResult(_ value: JSONValue) -> Bool {
        guard case .object(let object) = value else { return false }
        guard let toolsValue = object["tools"] else { return false }
        if case .array = toolsValue {
            return true
        }
        return false
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

        guard upstreamIndex == 0, config.eagerInitialize else { return }
        let shouldRetryEagerInit = initState.withLockedValue { state -> Bool in
            let shouldRetry = state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure && state.initResult == nil
            if shouldRetry {
                state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
            }
            return shouldRetry
        }
        if shouldRetryEagerInit {
            startEagerInitializePrimary()
        }
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
