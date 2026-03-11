import Foundation
import NIO
import ProxyCore

extension SessionManager {
    func startEagerInitializePrimary() {
        var shouldSend = false
        var shouldScheduleTimeout = false
        let upstreamId: Int64
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
        initState.withLockedValue { state in
            state.primaryInitUpstreamId = upstreamId
        }
        markUpstreamInitInFlight(upstreamIndex: 0, upstreamId: upstreamId)

        let request = makeInternalInitializeRequest(id: upstreamId)
        if let data = try? JSONSerialization.data(withJSONObject: request, options: []) {
            sendUpstream(data, upstreamIndex: 0)
        } else {
            failInitPending(error: TimeoutError())
        }
    }

    func handleInitializeResponse(_ object: [String: Any], upstreamIndex: Int) {
        guard let resultValue = object["result"], let result = JSONValue(any: resultValue) else {
            if upstreamIndex == 0 {
                if let errorObject = object["error"] as? [String: Any], !errorObject.isEmpty {
                    completeInitPendingWithError(errorObject)
                } else {
                    failInitPending(error: TimeoutError())
                }
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

        let update = initState.withLockedValue {
            state -> (pending: [InitPending], timeout: Scheduled<Void>?, shouldWarmSecondary: Bool)?
            in
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
            if sessionStillMatchesPendingInitialize(
                sessionId: item.sessionId,
                sessionGeneration: item.sessionGeneration
            ) {
                setInitializeUpstreamIndexIfNeeded(
                    sessionId: item.sessionId,
                    upstreamIndex: upstreamIndex,
                    preferOnNextPin: false
                )
            }
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

        refreshToolsListIfNeeded()
    }

    func encodeInitializeResponse(originalId: RPCId, result: JSONValue) -> ByteBuffer? {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalId.value.foundationObject,
            "result": result.foundationObject,
        ]
        guard JSONSerialization.isValidJSONObject(response),
            let data = try? JSONSerialization.data(withJSONObject: response, options: [])
        else {
            return nil
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func encodeInitializeErrorResponse(originalId: RPCId, errorObject: [String: Any])
        -> ByteBuffer?
    {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalId.value.foundationObject,
            "error": errorObject,
        ]
        guard JSONSerialization.isValidJSONObject(response),
            let data = try? JSONSerialization.data(withJSONObject: response, options: [])
        else {
            return nil
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func completeInitPendingWithError(_ errorObject: [String: Any]) {
        let result = initState.withLockedValue {
            state -> (
                pending: [InitPending], timeout: Scheduled<Void>?, upstreamId: Int64?,
                shouldRetryEagerInit: Bool
            )? in
            if state.isShuttingDown {
                return nil
            }
            let shouldRetryEagerInit =
                state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure
                && state.initResult == nil
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
            clearInitializeUpstreamIndex(
                sessionId: item.sessionId,
                onlyIfGeneration: item.sessionGeneration
            )
            if let buffer = encodeInitializeErrorResponse(
                originalId: item.originalId, errorObject: errorObject)
            {
                item.eventLoop.execute {
                    item.promise.succeed(buffer)
                }
            } else {
                item.eventLoop.execute {
                    item.promise.fail(TimeoutError())
                }
            }
        }

        if result.shouldRetryEagerInit, config.eagerInitialize {
            startEagerInitializePrimary()
        }
    }

    func sendInitializedNotificationIfNeeded(upstreamIndex: Int) {
        let shouldSend = upstreamPool.markDidSendInitializedIfNeeded(upstreamIndex: upstreamIndex)
        guard shouldSend else { return }

        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: notification, options: []) {
            sendUpstream(data, upstreamIndex: upstreamIndex)
        }
    }

    func scheduleInitTimeout() {
        guard
            let timeoutAmount = MCPMethodDispatcher.timeoutForInitialize(
                defaultSeconds: config.requestTimeout)
        else {
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

    func failInitPending(error: Error) {
        let result = initState.withLockedValue {
            state -> (
                pending: [InitPending], timeout: Scheduled<Void>?, upstreamId: Int64?,
                shouldRetryEagerInit: Bool
            )? in
            if state.isShuttingDown {
                return nil
            }
            let shouldRetryEagerInit =
                state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure
                && state.initResult == nil
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
            clearInitializeUpstreamIndex(
                sessionId: item.sessionId,
                onlyIfGeneration: item.sessionGeneration
            )
            item.eventLoop.execute {
                item.promise.fail(error)
            }
        }

        if result.shouldRetryEagerInit, config.eagerInitialize {
            startEagerInitializePrimary()
        }
    }

    func markUpstreamInitInFlight(upstreamIndex: Int, upstreamId: Int64) {
        upstreamPool.markInitInFlight(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
    }

    func clearUpstreamInitInFlight(upstreamIndex: Int) {
        upstreamPool.clearInitInFlight(upstreamIndex: upstreamIndex)
    }

    func clearUpstreamState(upstreamIndex: Int) {
        let timeout = upstreamPool.clearUpstreamState(upstreamIndex: upstreamIndex)
        timeout?.cancel()
        debugRecorder.resetUpstream(upstreamIndex)
    }

    func markUpstreamInitialized(upstreamIndex: Int) {
        let timeout = upstreamPool.markInitialized(upstreamIndex: upstreamIndex)
        timeout?.cancel()
    }

    func warmUpSecondaryUpstreams() {
        guard upstreams.count > 1 else { return }
        for upstreamIndex in 1..<upstreams.count {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
        }
    }

    func toolsListInternalSessionId() -> String {
        toolsListCache.internalSessionId { hasSession(id: $0) }
    }

    func makeInternalInitializeRequest(id: Int64) -> [String: Any] {
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
