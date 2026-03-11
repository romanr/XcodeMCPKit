import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOConcurrencyHelpers
import XcodeMCPProxyCore
import XcodeMCPProxyUpstream

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

    package struct DebugUpstreamState: Sendable {
        package var recentStderr: [ProxyDebugEvent] = []
        package var lastDecodeError: ProxyDebugEvent?
        package var lastBridgeError: ProxyDebugEvent?
        package var resyncCount = 0
        package var lastResyncAt: Date?
        package var lastResyncDroppedBytes: Int?
        package var lastResyncPreview: String?
        package var bufferedStdoutBytes = 0
    }

    package struct DebugState: Sendable {
        package var upstreams: [DebugUpstreamState] = []
        package var recentTraffic: [ProxyDebugTrafficEvent] = []
    }

    package struct InitPending: Sendable {
        package let eventLoop: EventLoop
        package let promise: EventLoopPromise<ByteBuffer>
        package let sessionId: String
        package let sessionGeneration: UInt64
        package let originalId: RPCId
    }

    package struct ToolsListState: Sendable {
        package var cachedResult: JSONValue?
        // Tracks a best-effort warmup to populate the in-memory tools/list cache once.
        package var warmupInFlight = false
        package var internalSessionId: String?
    }

    package struct SessionState: Sendable {
        package struct SessionRecord: Sendable {
            package let context: SessionContext
            package let generation: UInt64
            package var pinnedUpstreamIndex: Int?
            package var initializeUpstreamIndex: Int?
            package var preferInitializeUpstreamOnNextPin: Bool
            package var didReceiveInitializeUpstreamMessage: Bool
        }

        package var sessions: [String: SessionRecord] = [:]
        package var nextGeneration: UInt64 = 0
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

    package let sessionsState = NIOLockedValueBox(SessionState())
    package let initState = NIOLockedValueBox(InitState())
    package let upstreamTaskBox = NIOLockedValueBox<[Task<Void, Never>]>([])
    package let debugState = NIOLockedValueBox(DebugState())
    package let eventLoop: EventLoop
    package let idMapper: UpstreamIdMapper
    package let config: ProxyConfig
    package let logger: Logger = ProxyLogging.make("session")
    package let upstreams: [any UpstreamClient]
    package let toolsListState = NIOLockedValueBox(ToolsListState())
    package let debugTrafficLimit = 50
    package let debugStderrLimit = 20

    package struct UpstreamState: Sendable {
        package var isInitialized = false
        package var initInFlight = false
        package var initTimeout: Scheduled<Void>?
        package var didSendInitialized = false
        package var initUpstreamId: Int64?
        package var healthState: UpstreamHealthState = .healthy
        package var consecutiveRequestTimeouts = 0
        package var healthProbeInFlight = false
        package var healthProbeGeneration: UInt64 = 0
        package var consecutiveToolsListFailures: Int = 0
        package var lastToolsListSuccessUptimeNs: UInt64?
    }

    package struct UpstreamPoolState: Sendable {
        package var upstreamStates: [UpstreamState] = []
        package var nextPick: Int = 0
    }

    package let upstreamState = NIOLockedValueBox(UpstreamPoolState())

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
        self.idMapper = UpstreamIdMapper(upstreamCount: upstreams.count)
        upstreamState.withLockedValue { state in
            state.upstreamStates = Array(repeating: UpstreamState(), count: upstreams.count)
            state.nextPick = 0
        }
        debugState.withLockedValue { state in
            state.upstreams = Array(repeating: DebugUpstreamState(), count: upstreams.count)
            state.recentTraffic = []
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
        sessionsState.withLockedValue { state in
            if let existing = state.sessions[id] {
                return existing.context
            }
            let context = SessionContext(id: id, config: config)
            state.nextGeneration &+= 1
            state.sessions[id] = SessionState.SessionRecord(
                context: context,
                generation: state.nextGeneration,
                pinnedUpstreamIndex: nil,
                initializeUpstreamIndex: nil,
                preferInitializeUpstreamOnNextPin: false,
                didReceiveInitializeUpstreamMessage: false
            )
            return context
        }
    }

    package func hasSession(id: String) -> Bool {
        sessionsState.withLockedValue { state in
            state.sessions[id] != nil
        }
    }

    package func removeSession(id: String) {
        let context = sessionsState.withLockedValue { state in
            state.sessions.removeValue(forKey: id)?.context
        }
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

    package func isInitialized() -> Bool {
        initState.withLockedValue { $0.initResult != nil }
    }

    package func cachedToolsListResult() -> JSONValue? {
        toolsListState.withLockedValue { state in
            return state.cachedResult
        }
    }

    package func setCachedToolsListResult(_ result: JSONValue) {
        guard isValidToolsListResult(result) else { return }
        toolsListState.withLockedValue { state in
            state.cachedResult = result
        }
    }

    package func refreshToolsListIfNeeded() {
        guard config.prewarmToolsList else { return }
        guard isInitialized() else { return }

        let shouldStart = toolsListState.withLockedValue { state -> Bool in
            // If we already cached a valid tool list, keep it stable for the lifetime of this proxy process.
            // tools/list is not expected to change during normal operation, and background refreshes can cause
            // upstream churn (including Xcode permission dialogs) when upstreams are slow or flaky.
            if state.cachedResult != nil {
                return false
            }
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

    package func chooseUpstreamIndex(sessionId: String, shouldPin: Bool) -> Int? {
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        var probesToStart: [(upstreamIndex: Int, probeGeneration: UInt64)] = []
        probesToStart.reserveCapacity(2)

        var pinned = sessionsState.withLockedValue { state in
            state.sessions[sessionId]?.pinnedUpstreamIndex
        }
        if let pinnedIndex = pinned {
            let isUsable = upstreamState.withLockedValue { state in
                guard pinnedIndex >= 0, pinnedIndex < state.upstreamStates.count else {
                    return false
                }
                let health = classifyHealthAndCollectProbeIfNeeded(
                    upstreamIndex: pinnedIndex,
                    nowUptimeNs: nowUptimeNs,
                    state: &state,
                    probesToStart: &probesToStart
                )
                let isHealthyEnough: Bool
                switch health {
                case .healthy, .degraded:
                    isHealthyEnough = true
                case .quarantined:
                    isHealthyEnough = false
                }
                return isHealthyEnough && state.upstreamStates[pinnedIndex].isInitialized
            }
            if isUsable {
                return pinnedIndex
            }

            sessionsState.withLockedValue { state in
                state.sessions[sessionId]?.pinnedUpstreamIndex = nil
                state.sessions[sessionId]?.initializeUpstreamIndex = nil
                state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
                state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
            }
            pinned = nil
        }

        let preferredInitializeUpstreamIndex = sessionsState.withLockedValue { state -> Int? in
            guard let record = state.sessions[sessionId],
                record.pinnedUpstreamIndex == nil,
                (record.preferInitializeUpstreamOnNextPin || record.didReceiveInitializeUpstreamMessage),
                let upstreamIndex = record.initializeUpstreamIndex
            else {
                return nil
            }
            return upstreamIndex
        }

        if shouldPin, let preferredInitializeUpstreamIndex {
            let isUsable = upstreamState.withLockedValue { state in
                guard preferredInitializeUpstreamIndex >= 0,
                    preferredInitializeUpstreamIndex < state.upstreamStates.count
                else {
                    return false
                }
                let health = classifyHealthAndCollectProbeIfNeeded(
                    upstreamIndex: preferredInitializeUpstreamIndex,
                    nowUptimeNs: nowUptimeNs,
                    state: &state,
                    probesToStart: &probesToStart
                )
                let isHealthyEnough: Bool
                switch health {
                case .healthy, .degraded:
                    isHealthyEnough = true
                case .quarantined:
                    isHealthyEnough = false
                }
                return isHealthyEnough
                    && state.upstreamStates[preferredInitializeUpstreamIndex].isInitialized
            }
            if isUsable {
                for probe in probesToStart {
                    probeUpstreamHealth(
                        upstreamIndex: probe.upstreamIndex,
                        probeGeneration: probe.probeGeneration
                    )
                }
                sessionsState.withLockedValue { state in
                    state.sessions[sessionId]?.pinnedUpstreamIndex = preferredInitializeUpstreamIndex
                    state.sessions[sessionId]?.initializeUpstreamIndex = nil
                    state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
                    state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
                }
                return preferredInitializeUpstreamIndex
            }

            sessionsState.withLockedValue { state in
                state.sessions[sessionId]?.initializeUpstreamIndex = nil
                state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
                state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
            }
        }

        let chosen = upstreamState.withLockedValue { state -> Int? in
            let count = state.upstreamStates.count
            guard count > 0 else { return nil }

            let rawStart = state.nextPick % count
            let start = rawStart >= 0 ? rawStart : rawStart + count
            state.nextPick &+= 1

            var degradedCandidate: Int?
            for offset in 0..<count {
                let candidate = (start + offset) % count
                guard state.upstreamStates[candidate].isInitialized else { continue }
                let health = classifyHealthAndCollectProbeIfNeeded(
                    upstreamIndex: candidate,
                    nowUptimeNs: nowUptimeNs,
                    state: &state,
                    probesToStart: &probesToStart
                )
                switch health {
                case .healthy:
                    return candidate
                case .degraded:
                    if degradedCandidate == nil {
                        degradedCandidate = candidate
                    }
                case .quarantined:
                    continue
                }
            }
            return degradedCandidate
        }

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
            sessionsState.withLockedValue { state in
                state.sessions[sessionId]?.pinnedUpstreamIndex = chosen
                state.sessions[sessionId]?.initializeUpstreamIndex = nil
                state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
                state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
            }
        }
        return chosen
    }

    func chooseInitializeUpstreamIndex(sessionId: String) -> Int? {
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        var probesToStart: [(upstreamIndex: Int, probeGeneration: UInt64)] = []
        probesToStart.reserveCapacity(1)

        let hintedUpstreamIndex = sessionsState.withLockedValue { state -> Int? in
            if let pinned = state.sessions[sessionId]?.pinnedUpstreamIndex {
                return pinned
            }
            return state.sessions[sessionId]?.initializeUpstreamIndex
        }

        if let hintedUpstreamIndex {
            let isUsable = upstreamState.withLockedValue { state in
                guard hintedUpstreamIndex >= 0, hintedUpstreamIndex < state.upstreamStates.count else {
                    return false
                }
                let health = classifyHealthAndCollectProbeIfNeeded(
                    upstreamIndex: hintedUpstreamIndex,
                    nowUptimeNs: nowUptimeNs,
                    state: &state,
                    probesToStart: &probesToStart
                )
                let isHealthyEnough: Bool
                switch health {
                case .healthy, .degraded:
                    isHealthyEnough = true
                case .quarantined:
                    isHealthyEnough = false
                }
                return isHealthyEnough && state.upstreamStates[hintedUpstreamIndex].isInitialized
            }

            for probe in probesToStart {
                probeUpstreamHealth(
                    upstreamIndex: probe.upstreamIndex,
                    probeGeneration: probe.probeGeneration
                )
            }

            if isUsable {
                return hintedUpstreamIndex
            }

            sessionsState.withLockedValue { state in
                if state.sessions[sessionId]?.pinnedUpstreamIndex == nil {
                    state.sessions[sessionId]?.initializeUpstreamIndex = nil
                    state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
                }
            }
        }

        return chooseUpstreamIndex(sessionId: sessionId, shouldPin: false)
    }

    func setInitializeUpstreamIndexIfNeeded(
        sessionId: String,
        upstreamIndex: Int,
        preferOnNextPin: Bool
    ) {
        sessionsState.withLockedValue { state in
            guard let record = state.sessions[sessionId] else { return }
            if record.pinnedUpstreamIndex == nil {
                state.sessions[sessionId]?.initializeUpstreamIndex = upstreamIndex
                state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = preferOnNextPin
                state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
            } else {
                state.sessions[sessionId]?.initializeUpstreamIndex = nil
                state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
                state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
            }
        }
    }

    func clearInitializeUpstreamIndex(
        sessionId: String,
        onlyIfGeneration sessionGeneration: UInt64? = nil
    ) {
        sessionsState.withLockedValue { state in
            guard let record = state.sessions[sessionId] else { return }
            if let sessionGeneration, record.generation != sessionGeneration {
                return
            }
            state.sessions[sessionId]?.initializeUpstreamIndex = nil
            state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
            state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
        }
    }

    func sessionStillMatchesPendingInitialize(
        sessionId: String,
        sessionGeneration: UInt64
    ) -> Bool {
        sessionsState.withLockedValue { state in
            guard let record = state.sessions[sessionId] else { return false }
            return record.generation == sessionGeneration
        }
    }

    func classifyHealthAndCollectProbeIfNeeded(
        upstreamIndex: Int,
        nowUptimeNs: UInt64,
        state: inout UpstreamPoolState,
        probesToStart: inout [(upstreamIndex: Int, probeGeneration: UInt64)]
    ) -> UpstreamHealthState {
        guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else {
            return .quarantined(untilUptimeNs: nowUptimeNs)
        }
        let current = state.upstreamStates[upstreamIndex].healthState
        switch current {
        case .healthy:
            return .healthy
        case .degraded:
            return .degraded
        case .quarantined(let untilUptimeNs):
            if nowUptimeNs < untilUptimeNs {
                return .quarantined(untilUptimeNs: untilUptimeNs)
            }
            if state.upstreamStates[upstreamIndex].healthProbeInFlight == false {
                state.upstreamStates[upstreamIndex].healthProbeInFlight = true
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                probesToStart.append(
                    (
                        upstreamIndex: upstreamIndex,
                        probeGeneration: state.upstreamStates[upstreamIndex].healthProbeGeneration
                    ))
            }
            return .quarantined(untilUptimeNs: untilUptimeNs)
        }
    }

    package func registerInitialize(
        sessionId: String,
        originalId: RPCId,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        _ = session(id: sessionId)
        let sessionGeneration = sessionsState.withLockedValue { state in
            state.sessions[sessionId]?.generation ?? 0
        }
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
                let shouldPreferOnNextPin = upstreamState.withLockedValue { state in
                    state.upstreamStates.reduce(into: 0) { count, upstream in
                        guard upstream.isInitialized else { return }
                        switch upstream.healthState {
                        case .healthy, .degraded:
                            count += 1
                        case .quarantined:
                            break
                        }
                    } > 1
                }
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
