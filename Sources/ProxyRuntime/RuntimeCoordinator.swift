import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOConcurrencyHelpers
import ProxyCore

package final class SessionContext: Sendable {
    package let id: String
    package let router: ProxyRouter
    package let notificationHub: NotificationHub
    package let requestSequencer: SessionRequestSequencer

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
        self.requestSequencer = SessionRequestSequencer(sessionID: id)
    }
}

package protocol RuntimeCoordinating: Sendable {
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
    func chooseInitializeUpstreamIndex(sessionID: String) -> Int?
    func chooseUpstreamIndex(sessionID: String, shouldPin: Bool) -> Int?
    func assignUpstreamID(sessionID: String, originalID: RPCID, upstreamIndex: Int) -> Int64
    func removeUpstreamIDMapping(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func onRequestTimeout(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func onRequestSucceeded(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func sendUpstream(_ data: Data, upstreamIndex: Int)
    func debugSnapshot() -> ProxyDebugSnapshot
}

package final class RuntimeCoordinator: Sendable, RuntimeCoordinating {
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

    package let sessionStore: SessionStore
    package let initializeGate = InitializeGate()
    package let upstreamTaskBox = NIOLockedValueBox<[Task<Void, Never>]>([])
    package let debugRecorder: ProxyDebugRecorder
    package let eventLoop: EventLoop
    package let responseCorrelationStore: ResponseCorrelationStore
    package let config: ProxyConfig
    package let logger: Logger = ProxyLogging.make("session")
    package let upstreams: [any UpstreamClient]
    package let toolsListCache = ToolsListCache()
    package let initializeParamsOverride: [String: JSONValue]?

    package let upstreamSelectionPolicy: UpstreamSelectionPolicy

    package convenience init(config: ProxyConfig, eventLoop: EventLoop) {
        let count = max(1, min(config.upstreamProcessCount, 10))
        let upstreams = Self.makeDefaultUpstreams(
            config: config, sharedSessionID: config.upstreamSessionID, count: count)
        self.init(config: config, eventLoop: eventLoop, upstreams: upstreams)
    }

    package init(config: ProxyConfig, eventLoop: EventLoop, upstreams: [any UpstreamClient]) {
        precondition(!upstreams.isEmpty, "upstreams must not be empty")
        self.config = config
        self.eventLoop = eventLoop
        self.upstreams = upstreams
        self.sessionStore = SessionStore(config: config)
        self.debugRecorder = ProxyDebugRecorder(upstreamCount: upstreams.count)
        self.responseCorrelationStore = ResponseCorrelationStore(upstreamCount: upstreams.count)
        self.upstreamSelectionPolicy = UpstreamSelectionPolicy(upstreamCount: upstreams.count)
        self.initializeParamsOverride = ProxyFileConfigLoader.loadInitializeParamsOverride(
            configPath: config.configPath,
            logger: ProxyLogging.make("config")
        )

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

        startEagerInitializePrimary()
    }

    package func session(id: String) -> SessionContext {
        sessionStore.session(id: id)
    }

    package func hasSession(id: String) -> Bool {
        sessionStore.hasSession(id: id)
    }

    package func removeSession(id: String) {
        let context = sessionStore.removeSession(id: id)
        context?.notificationHub.closeAll()
    }

    package func shutdown() {
        let shutdownState = initializeGate.beginShutdown()
        let pendingInitializes = shutdownState.pending
        for pending in pendingInitializes {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
        shutdownState.timeout?.cancel()

        let upstreamTimeouts = upstreamSelectionPolicy.clearInitTimeoutsForShutdown()
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
        initializeGate.isInitialized()
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

        var pinned = sessionStore.pinnedUpstreamIndex(for: sessionID)
        if let pinnedIndex = pinned {
            let result = upstreamSelectionPolicy.evaluateUsableInitialized(
                index: pinnedIndex,
                nowUptimeNs: nowUptimeNs
            )
            probesToStart.append(contentsOf: result.1)
            let isUsable = result.0
            if isUsable {
                return pinnedIndex
            }

            sessionStore.clearRoutingState(for: sessionID)
            pinned = nil
        }

        let preferredInitializeUpstreamIndex = sessionStore.preferredInitializeUpstreamIndex(for: sessionID)

        if shouldPin, let preferredInitializeUpstreamIndex {
            let result = upstreamSelectionPolicy.evaluateUsableInitialized(
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
                sessionStore.pinSession(sessionID, to: preferredInitializeUpstreamIndex)
                return preferredInitializeUpstreamIndex
            }

            sessionStore.clearInitializeHintIfUnpinned(for: sessionID)
        }

        let chooseResult = upstreamSelectionPolicy.chooseBestInitializedUpstream(nowUptimeNs: nowUptimeNs)
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
            sessionStore.pinSession(sessionID, to: chosen)
        }
        return chosen
    }

    package func chooseInitializeUpstreamIndex(sessionID: String) -> Int? {
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        var probesToStart: [HealthProbeRequest] = []
        probesToStart.reserveCapacity(1)

        let hintedUpstreamIndex = sessionStore.hintedUpstreamIndex(for: sessionID)

        if let hintedUpstreamIndex {
            let result = upstreamSelectionPolicy.evaluateUsableInitialized(
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

            sessionStore.clearInitializeHintIfUnpinned(for: sessionID)
        }

        return chooseUpstreamIndex(sessionID: sessionID, shouldPin: false)
    }

    func setInitializeUpstreamIndexIfNeeded(
        sessionID: String,
        upstreamIndex: Int,
        preferOnNextPin: Bool
    ) {
        sessionStore.setInitializeUpstreamIfNeeded(
            sessionID: sessionID,
            upstreamIndex: upstreamIndex,
            preferOnNextPin: preferOnNextPin
        )
    }

    func clearInitializeUpstreamIndex(
        sessionID: String,
        onlyIfGeneration sessionGeneration: UInt64? = nil
    ) {
        sessionStore.clearInitializeUpstreamIndex(
            sessionID: sessionID,
            onlyIfGeneration: sessionGeneration
        )
    }

    func sessionStillMatchesPendingInitialize(
        sessionID: String,
        sessionGeneration: UInt64
    ) -> Bool {
        sessionStore.sessionStillMatchesPendingInitialize(
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
        let sessionGeneration = sessionStore.generation(of: sessionID) ?? 0
        let decision = initializeGate.registerInitialize(
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
                let shouldPreferOnNextPin = upstreamSelectionPolicy.initializedHealthyishCount() > 1
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
            let upstreamID = responseCorrelationStore.assignInitialize(upstreamIndex: 0)
            initializeGate.setPrimaryInitUpstreamID(upstreamID)
            markUpstreamInitInFlight(upstreamIndex: 0, upstreamID: upstreamID)
            let initRequest = makeInternalInitializeRequest(id: upstreamID)
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
