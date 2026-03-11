import Foundation
import NIO
import ProxyCore

extension RuntimeCoordinator {
    func startEagerInitializePrimary() {
        let decision = initializeGate.beginEagerInitializePrimary()
        let shouldSend = decision.shouldSendRequest
        let shouldScheduleTimeout = decision.shouldScheduleTimeout
        if shouldScheduleTimeout {
            scheduleInitTimeout()
        }
        guard shouldSend else { return }

        let upstreamID = responseCorrelationStore.assignInitialize(upstreamIndex: 0)
        initializeGate.setPrimaryInitUpstreamID(upstreamID)
        markUpstreamInitInFlight(upstreamIndex: 0, upstreamID: upstreamID)

        let request = makeInternalInitializeRequest(id: upstreamID)
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

        let update = initializeGate.completePrimaryInitializeSuccess(result: result)
        guard let update else { return }
        update.timeout?.cancel()

        for item in update.pending {
            if sessionStillMatchesPendingInitialize(
                sessionID: item.sessionID,
                sessionGeneration: item.sessionGeneration
            ) {
                setInitializeUpstreamIndexIfNeeded(
                    sessionID: item.sessionID,
                    upstreamIndex: upstreamIndex,
                    preferOnNextPin: false
                )
            }
            if let buffer = encodeInitializeResponse(originalID: item.originalID, result: result) {
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

    func encodeInitializeResponse(originalID: RPCID, result: JSONValue) -> ByteBuffer? {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
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

    func encodeInitializeErrorResponse(originalID: RPCID, errorObject: [String: Any])
        -> ByteBuffer?
    {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
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
        let result = initializeGate.completePrimaryInitializeFailure()
        guard let result else { return }
        result.timeout?.cancel()
        if let upstreamID = result.upstreamID {
            responseCorrelationStore.remove(upstreamIndex: 0, upstreamID: upstreamID)
        }
        clearUpstreamInitInFlight(upstreamIndex: 0)
        for item in result.pending {
            clearInitializeUpstreamIndex(
                sessionID: item.sessionID,
                onlyIfGeneration: item.sessionGeneration
            )
            if let buffer = encodeInitializeErrorResponse(
                originalID: item.originalID, errorObject: errorObject)
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

        if result.shouldRetryEagerInitialize, config.eagerInitialize {
            startEagerInitializePrimary()
        }
    }

    func sendInitializedNotificationIfNeeded(upstreamIndex: Int) {
        let shouldSend = upstreamSelectionPolicy.markDidSendInitializedIfNeeded(upstreamIndex: upstreamIndex)
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
        let previous = initializeGate.replaceInitTimeout(timeout)
        previous?.cancel()
    }

    func failInitPending(error: Error) {
        let result = initializeGate.completePrimaryInitializeFailure()
        guard let result else { return }
        result.timeout?.cancel()
        if let upstreamID = result.upstreamID {
            responseCorrelationStore.remove(upstreamIndex: 0, upstreamID: upstreamID)
        }
        clearUpstreamInitInFlight(upstreamIndex: 0)
        for item in result.pending {
            clearInitializeUpstreamIndex(
                sessionID: item.sessionID,
                onlyIfGeneration: item.sessionGeneration
            )
            item.eventLoop.execute {
                item.promise.fail(error)
            }
        }

        if result.shouldRetryEagerInitialize, config.eagerInitialize {
            startEagerInitializePrimary()
        }
    }

    func markUpstreamInitInFlight(upstreamIndex: Int, upstreamID: Int64) {
        upstreamSelectionPolicy.markInitInFlight(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
    }

    func clearUpstreamInitInFlight(upstreamIndex: Int) {
        upstreamSelectionPolicy.clearInitInFlight(upstreamIndex: upstreamIndex)
    }

    func clearUpstreamState(upstreamIndex: Int) {
        let timeout = upstreamSelectionPolicy.clearUpstreamState(upstreamIndex: upstreamIndex)
        timeout?.cancel()
        debugRecorder.resetUpstream(upstreamIndex)
    }

    func markUpstreamInitialized(upstreamIndex: Int) {
        let timeout = upstreamSelectionPolicy.markInitialized(upstreamIndex: upstreamIndex)
        timeout?.cancel()
    }

    func warmUpSecondaryUpstreams() {
        guard upstreams.count > 1 else { return }
        for upstreamIndex in 1..<upstreams.count {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
        }
    }

    func toolsListInternalSessionID() -> String {
        toolsListCache.internalSessionID { hasSession(id: $0) }
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
