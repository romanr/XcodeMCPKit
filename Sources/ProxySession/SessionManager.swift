import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOConcurrencyHelpers
import ProxyCore
import ProxyUpstream

package final class SessionContext: Sendable {
    package let id: String
    package let router: ProxyRouter
    package let notificationHub: NotificationHub

    package init(id: String, config: ProxyConfig) {
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

package protocol SessionManaging: Sendable {
    func session(id: String) -> SessionContext
    func hasSession(id: String) -> Bool
    func removeSession(id: String)
    func shutdown()
    func isInitialized() -> Bool
    func cachedToolsListResult() -> JSONValue?
    func setCachedToolsListResult(_ result: JSONValue)
    func refreshToolsListIfNeeded()
    func registerInitialize(
        sessionId: String,
        originalId: RPCId,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer>
    func chooseUpstreamIndex(sessionId: String, shouldPin: Bool) -> Int?
    func assignUpstreamId(sessionId: String, originalId: RPCId, upstreamIndex: Int) -> Int64
    func removeUpstreamIdMapping(sessionId: String, requestIdKey: String, upstreamIndex: Int)
    func onRequestTimeout(sessionId: String, requestIdKey: String, upstreamIndex: Int)
    func onRequestSucceeded(sessionId: String, requestIdKey: String, upstreamIndex: Int)
    func sendUpstream(_ data: Data, upstreamIndex: Int)
    func debugSnapshot() -> ProxyDebugSnapshot
}

package final class SessionManager: Sendable, SessionManaging {
    static let redactedDebugText = "<redacted>"

    struct TestSnapshot: Sendable {
        struct Upstream: Sendable {
            let isInitialized: Bool
            let initInFlight: Bool
            let healthState: UpstreamHealthState
        }

        struct Session: Sendable {
            let generation: UInt64
            let pinnedUpstreamIndex: Int?
            let initializeUpstreamIndex: Int?
            let preferInitializeUpstreamOnNextPin: Bool
            let didReceiveInitializeUpstreamMessage: Bool
        }

        let hasInitResult: Bool
        let initInFlight: Bool
        let didWarmSecondary: Bool
        let shouldRetryEagerInitializePrimaryAfterWarmInitFailure: Bool
        let upstreams: [Upstream]
    }

    package struct InitPending: Sendable {
        package let eventLoop: EventLoop
        package let promise: EventLoopPromise<ByteBuffer>
        package let sessionId: String
        package let sessionGeneration: UInt64
        package let originalId: RPCId
    }

    package struct InitState: Sendable {
        package var initResult: JSONValue?
        package var initPending: [InitPending] = []
        package var initInFlight = false
        package var initTimeout: Scheduled<Void>?
        package var isShuttingDown = false
        package var didWarmSecondary = false
        package var primaryInitUpstreamId: Int64?
        // If we drop the cached global init result while the primary is already performing a warm init,
        // retry the eager/global init once that warm init finishes unsuccessfully (error/timeout).
        package var shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
    }

    package let sessionRegistry: SessionRegistry
    package let initState = NIOLockedValueBox(InitState())
    package let upstreamTaskBox = NIOLockedValueBox<[Task<Void, Never>]>([])
    package let debugRecorder: ProxyDebugRecorder
    package let eventLoop: EventLoop
    package let idMapper: UpstreamIdMapper
    package let config: ProxyConfig
    package let logger: Logger = ProxyLogging.make("session")
    package let upstreams: [any UpstreamClient]
    package let toolsListCache = ToolsListCache()

    package let upstreamPool: UpstreamPool

    package convenience init(config: ProxyConfig, eventLoop: EventLoop) {
        let count = max(1, min(config.upstreamProcessCount, 10))
        let sharedSessionID = config.upstreamSessionID ?? UUID().uuidString
        let upstreams = Self.makeDefaultUpstreams(
            config: config, sharedSessionID: sharedSessionID, count: count)
        self.init(config: config, eventLoop: eventLoop, upstreams: upstreams)
    }

    package init(config: ProxyConfig, eventLoop: EventLoop, upstreams: [any UpstreamClient]) {
        precondition(!upstreams.isEmpty, "upstreams must not be empty")
        self.config = config
        self.eventLoop = eventLoop
        self.upstreams = upstreams
        self.sessionRegistry = SessionRegistry(config: config)
        self.debugRecorder = ProxyDebugRecorder(upstreamCount: upstreams.count)
        self.idMapper = UpstreamIdMapper(upstreamCount: upstreams.count)
        self.upstreamPool = UpstreamPool(upstreamCount: upstreams.count)

        var tasks: [Task<Void, Never>] = []
        tasks.reserveCapacity(upstreams.count)
        for (upstreamIndex, upstream) in upstreams.enumerated() {
            let task = Task { [weak self] in
                guard let self else { return }
                for await event in upstream.events {
                    switch event {
                    case .message(let data):
                        self.routeUpstreamMessage(data, upstreamIndex: upstreamIndex)
                    case .stderr(let message):
                        self.handleUpstreamStderr(message, upstreamIndex: upstreamIndex)
                    case .stdoutRecovery(let recovery):
                        self.handleUpstreamRecovery(recovery, upstreamIndex: upstreamIndex)
                    case .stdoutBufferSize(let size):
                        self.handleBufferedStdoutBytes(size, upstreamIndex: upstreamIndex)
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

    package func session(id: String) -> SessionContext {
        sessionRegistry.session(id: id)
    }

    package func hasSession(id: String) -> Bool {
        sessionRegistry.hasSession(id: id)
    }

    package func removeSession(id: String) {
        let context = sessionRegistry.removeSession(id: id)
        context?.notificationHub.closeAll()
    }

    package func shutdown() {
        let pendingInitializes = initState.withLockedValue { state -> [InitPending] in
            state.isShuttingDown = true
            state.initInFlight = false
            let pending = state.initPending
            state.initPending.removeAll()
            return pending
        }
        for pending in pendingInitializes {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }

        let globalTimeout = initState.withLockedValue { state -> Scheduled<Void>? in
            let existing = state.initTimeout
            state.initTimeout = nil
            return existing
        }
        globalTimeout?.cancel()

        let upstreamTimeouts = upstreamPool.clearInitTimeoutsForShutdown()
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

    package func isInitialized() -> Bool {
        initState.withLockedValue { $0.initResult != nil }
    }

    package func cachedToolsListResult() -> JSONValue? {
        toolsListCache.cachedResult()
    }

    package func setCachedToolsListResult(_ result: JSONValue) {
        guard isValidToolsListResult(result) else { return }
        toolsListCache.setCachedResult(result)
    }

    package func refreshToolsListIfNeeded() {
        let shouldStart = toolsListCache.beginWarmupIfNeeded(
            isEnabled: config.prewarmToolsList,
            isInitialized: isInitialized()
        )
        guard shouldStart else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.refreshToolsList()
        }
    }

    package func chooseUpstreamIndex(sessionId: String, shouldPin: Bool) -> Int? {
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        var probesToStart: [HealthProbeRequest] = []
        probesToStart.reserveCapacity(2)

        var pinned = sessionRegistry.pinnedUpstreamIndex(for: sessionId)
        if let pinnedIndex = pinned {
            let result = upstreamPool.evaluateUsableInitialized(
                index: pinnedIndex,
                nowUptimeNs: nowUptimeNs
            )
            probesToStart.append(contentsOf: result.1)
            let isUsable = result.0
            if isUsable {
                return pinnedIndex
            }

            sessionRegistry.clearRoutingState(for: sessionId)
            pinned = nil
        }

        let preferredInitializeUpstreamIndex = sessionRegistry.preferredInitializeUpstreamIndex(for: sessionId)

        if shouldPin, let preferredInitializeUpstreamIndex {
            let result = upstreamPool.evaluateUsableInitialized(
                index: preferredInitializeUpstreamIndex,
                nowUptimeNs: nowUptimeNs
            )
            probesToStart.append(contentsOf: result.1)
            let isUsable = result.0
            if isUsable {
                for probe in probesToStart {
                    probeUpstreamHealth(
                        upstreamIndex: probe.upstreamIndex,
                        probeGeneration: probe.probeGeneration
                    )
                }
                sessionRegistry.pinSession(sessionId, to: preferredInitializeUpstreamIndex)
                return preferredInitializeUpstreamIndex
            }

            sessionRegistry.clearInitializeHintIfUnpinned(for: sessionId)
        }

        let chooseResult = upstreamPool.chooseBestInitializedUpstream(nowUptimeNs: nowUptimeNs)
        let chosen = chooseResult.0
        probesToStart.append(contentsOf: chooseResult.1)

        for probe in probesToStart {
            probeUpstreamHealth(
                upstreamIndex: probe.upstreamIndex,
                probeGeneration: probe.probeGeneration
            )
        }

        guard let chosen else {
            return nil
        }

        if pinned == nil, shouldPin {
            sessionRegistry.pinSession(sessionId, to: chosen)
        }
        return chosen
    }

    func chooseInitializeUpstreamIndex(sessionId: String) -> Int? {
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        var probesToStart: [HealthProbeRequest] = []
        probesToStart.reserveCapacity(1)

        let hintedUpstreamIndex = sessionRegistry.hintedUpstreamIndex(for: sessionId)

        if let hintedUpstreamIndex {
            let result = upstreamPool.evaluateUsableInitialized(
                index: hintedUpstreamIndex,
                nowUptimeNs: nowUptimeNs
            )
            probesToStart.append(contentsOf: result.1)
            let isUsable = result.0

            for probe in probesToStart {
                probeUpstreamHealth(
                    upstreamIndex: probe.upstreamIndex,
                    probeGeneration: probe.probeGeneration
                )
            }

            if isUsable {
                return hintedUpstreamIndex
            }

            sessionRegistry.clearInitializeHintIfUnpinned(for: sessionId)
        }

        return chooseUpstreamIndex(sessionId: sessionId, shouldPin: false)
    }

    func setInitializeUpstreamIndexIfNeeded(
        sessionId: String,
        upstreamIndex: Int,
        preferOnNextPin: Bool
    ) {
        sessionRegistry.setInitializeUpstreamIfNeeded(
            sessionId: sessionId,
            upstreamIndex: upstreamIndex,
            preferOnNextPin: preferOnNextPin
        )
    }

    func clearInitializeUpstreamIndex(
        sessionId: String,
        onlyIfGeneration sessionGeneration: UInt64? = nil
    ) {
        sessionRegistry.clearInitializeUpstreamIndex(
            sessionId: sessionId,
            onlyIfGeneration: sessionGeneration
        )
    }

    func sessionStillMatchesPendingInitialize(
        sessionId: String,
        sessionGeneration: UInt64
    ) -> Bool {
        sessionRegistry.sessionStillMatchesPendingInitialize(
            sessionId: sessionId,
            sessionGeneration: sessionGeneration
        )
    }

    package func registerInitialize(
        sessionId: String,
        originalId: RPCId,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        _ = session(id: sessionId)
        let sessionGeneration = sessionRegistry.generation(of: sessionId) ?? 0
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
                    sessionId: sessionId,
                    sessionGeneration: sessionGeneration,
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
            _ = session(id: sessionId)
            if let upstreamIndex = chooseInitializeUpstreamIndex(sessionId: sessionId) {
                let shouldPreferOnNextPin = upstreamPool.initializedHealthyishCount() > 1
                setInitializeUpstreamIndexIfNeeded(
                    sessionId: sessionId,
                    upstreamIndex: upstreamIndex,
                    preferOnNextPin: shouldPreferOnNextPin
                )
            }
            if let buffer = encodeInitializeResponse(originalId: originalId, result: cachedResult) {
                return eventLoop.makeSucceededFuture(buffer)
            }
            return eventLoop.makeFailedFuture(TimeoutError())
        }

        if shuttingDown {
            return eventLoop.makeFailedFuture(TimeoutError())
        }

        if pendingPromise != nil {
            _ = session(id: sessionId)
            setInitializeUpstreamIndexIfNeeded(
                sessionId: sessionId,
                upstreamIndex: 0,
                preferOnNextPin: false
            )
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

    package func registerInitialize(
        originalId: RPCId,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        registerInitialize(
            sessionId: "__initialize_pending__:\(originalId.key)",
            originalId: originalId,
            requestObject: requestObject,
            on: eventLoop
        )
    }

}
