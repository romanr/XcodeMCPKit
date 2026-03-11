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
        sessionID: String,
        originalID: RPCID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer>
    func chooseUpstreamIndex(sessionID: String, shouldPin: Bool) -> Int?
    func assignUpstreamID(sessionID: String, originalID: RPCID, upstreamIndex: Int) -> Int64
    func removeUpstreamIDMapping(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func onRequestTimeout(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func onRequestSucceeded(sessionID: String, requestIDKey: String, upstreamIndex: Int)
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

    package let sessionRegistry: SessionRegistry
    package let initializeCoordinator = InitializeCoordinator()
    package let upstreamTaskBox = NIOLockedValueBox<[Task<Void, Never>]>([])
    package let debugRecorder: ProxyDebugRecorder
    package let eventLoop: EventLoop
    package let idMapper: UpstreamIDMapper
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
        self.idMapper = UpstreamIDMapper(upstreamCount: upstreams.count)
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
        let shutdownState = initializeCoordinator.beginShutdown()
        let pendingInitializes = shutdownState.pending
        for pending in pendingInitializes {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
        shutdownState.timeout?.cancel()

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
        initializeCoordinator.isInitialized()
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

    package func chooseUpstreamIndex(sessionID: String, shouldPin: Bool) -> Int? {
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        var probesToStart: [HealthProbeRequest] = []
        probesToStart.reserveCapacity(2)

        var pinned = sessionRegistry.pinnedUpstreamIndex(for: sessionID)
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

            sessionRegistry.clearRoutingState(for: sessionID)
            pinned = nil
        }

        let preferredInitializeUpstreamIndex = sessionRegistry.preferredInitializeUpstreamIndex(for: sessionID)

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
                sessionRegistry.pinSession(sessionID, to: preferredInitializeUpstreamIndex)
                return preferredInitializeUpstreamIndex
            }

            sessionRegistry.clearInitializeHintIfUnpinned(for: sessionID)
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
            sessionRegistry.pinSession(sessionID, to: chosen)
        }
        return chosen
    }

    func chooseInitializeUpstreamIndex(sessionID: String) -> Int? {
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        var probesToStart: [HealthProbeRequest] = []
        probesToStart.reserveCapacity(1)

        let hintedUpstreamIndex = sessionRegistry.hintedUpstreamIndex(for: sessionID)

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

            sessionRegistry.clearInitializeHintIfUnpinned(for: sessionID)
        }

        return chooseUpstreamIndex(sessionID: sessionID, shouldPin: false)
    }

    func setInitializeUpstreamIndexIfNeeded(
        sessionID: String,
        upstreamIndex: Int,
        preferOnNextPin: Bool
    ) {
        sessionRegistry.setInitializeUpstreamIfNeeded(
            sessionID: sessionID,
            upstreamIndex: upstreamIndex,
            preferOnNextPin: preferOnNextPin
        )
    }

    func clearInitializeUpstreamIndex(
        sessionID: String,
        onlyIfGeneration sessionGeneration: UInt64? = nil
    ) {
        sessionRegistry.clearInitializeUpstreamIndex(
            sessionID: sessionID,
            onlyIfGeneration: sessionGeneration
        )
    }

    func sessionStillMatchesPendingInitialize(
        sessionID: String,
        sessionGeneration: UInt64
    ) -> Bool {
        sessionRegistry.sessionStillMatchesPendingInitialize(
            sessionID: sessionID,
            sessionGeneration: sessionGeneration
        )
    }

    package func registerInitialize(
        sessionID: String,
        originalID: RPCID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        _ = session(id: sessionID)
        let sessionGeneration = sessionRegistry.generation(of: sessionID) ?? 0
        let decision = initializeCoordinator.registerInitialize(
            sessionID: sessionID,
            sessionGeneration: sessionGeneration,
            originalID: originalID,
            on: eventLoop
        )
        let cachedResult = decision.cachedResult
        let shuttingDown = decision.isShuttingDown
        let pendingPromise = decision.promise
        let shouldSend = decision.shouldSendRequest
        let shouldScheduleTimeout = decision.shouldScheduleTimeout

        if shouldScheduleTimeout {
            scheduleInitTimeout()
        }

        if let cachedResult {
            _ = session(id: sessionID)
            if let upstreamIndex = chooseInitializeUpstreamIndex(sessionID: sessionID) {
                let shouldPreferOnNextPin = upstreamPool.initializedHealthyishCount() > 1
                setInitializeUpstreamIndexIfNeeded(
                    sessionID: sessionID,
                    upstreamIndex: upstreamIndex,
                    preferOnNextPin: shouldPreferOnNextPin
                )
            }
            if let buffer = encodeInitializeResponse(originalID: originalID, result: cachedResult) {
                return eventLoop.makeSucceededFuture(buffer)
            }
            return eventLoop.makeFailedFuture(TimeoutError())
        }

        if shuttingDown {
            return eventLoop.makeFailedFuture(TimeoutError())
        }

        if pendingPromise != nil {
            _ = session(id: sessionID)
            setInitializeUpstreamIndexIfNeeded(
                sessionID: sessionID,
                upstreamIndex: 0,
                preferOnNextPin: false
            )
        }

        if shouldSend {
            var initRequest = requestObject
            let upstreamID = idMapper.assignInitialize(upstreamIndex: 0)
            initializeCoordinator.setPrimaryInitUpstreamID(upstreamID)
            markUpstreamInitInFlight(upstreamIndex: 0, upstreamID: upstreamID)
            initRequest["id"] = upstreamID
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
        originalID: RPCID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        registerInitialize(
            sessionID: "__initialize_pending__:\(originalID.key)",
            originalID: originalID,
            requestObject: requestObject,
            on: eventLoop
        )
    }

}
