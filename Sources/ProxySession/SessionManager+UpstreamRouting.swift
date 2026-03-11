import Foundation
import NIO
import ProxyCore
import ProxyUpstream

extension SessionManager {
    func routeUpstreamMessage(_ data: Data, upstreamIndex: Int) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            routeUnmappedUpstreamMessage(data, upstreamIndex: upstreamIndex)
            return
        }

        if var object = json as? [String: Any],
            let upstreamId = upstreamId(from: object["id"]),
            let mapping = idMapper.consume(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
        {
            if mapping.isInitialize {
                handleInitializeResponse(object, upstreamIndex: upstreamIndex)
                return
            }
            if let sessionId = mapping.sessionId, let originalId = mapping.originalId {
                object["id"] = originalId.value.foundationObject
                if let rewritten = try? JSONSerialization.data(withJSONObject: object, options: [])
                {
                    recordTraffic(
                        upstreamIndex: upstreamIndex,
                        direction: "inbound",
                        data: rewritten
                    )
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
                    let mapping = idMapper.consume(
                        upstreamIndex: upstreamIndex, upstreamId: upstreamId)
                else {
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
            if rewrittenAny, let sessionId,
                let rewritten = try? JSONSerialization.data(
                    withJSONObject: transformed, options: [])
            {
                recordTraffic(
                    upstreamIndex: upstreamIndex,
                    direction: "inbound",
                    data: rewritten
                )
                let target = session(id: sessionId)
                target.router.handleIncoming(rewritten)
                return
            }
        }

        routeUnmappedUpstreamMessage(data, upstreamIndex: upstreamIndex)
    }

    func handleUpstreamExit(_ status: Int32, upstreamIndex: Int) {
        let globalInit = initializeCoordinator.handleUpstreamExit(upstreamIndex: upstreamIndex)
        guard let globalInit else { return }

        if upstreamIndex == 0 && globalInit.wasInFlight {
            globalInit.timeout?.cancel()
            if let upstreamId = globalInit.primaryInitUpstreamId {
                idMapper.remove(upstreamIndex: 0, upstreamId: upstreamId)
            }
            for item in globalInit.pending {
                clearInitializeUpstreamIndex(
                    sessionId: item.sessionId,
                    onlyIfGeneration: item.sessionGeneration
                )
                item.eventLoop.execute {
                    item.promise.fail(TimeoutError())
                }
            }
        }

        clearUpstreamState(upstreamIndex: upstreamIndex)
        idMapper.reset(upstreamIndex: upstreamIndex)

        let clearedPins = sessionRegistry.clearPinnedSessions(forUpstreamIndex: upstreamIndex)
        if clearedPins > 0 {
            logger.debug(
                "Cleared pinned sessions for exited upstream",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"), "cleared": .string("\(clearedPins)"),
                ])
        }

        let shouldResetGlobalInit: Bool
        if globalInit.hadGlobalInit {
            shouldResetGlobalInit = !upstreamPool.anyInitialized()
        } else {
            shouldResetGlobalInit = false
        }
        if shouldResetGlobalInit {
            initializeCoordinator.resetCachedInitializeResult()
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
                    let primaryInitInFlight = upstreamPool.primaryInitInFlight()
                    if primaryInitInFlight {
                        initializeCoordinator
                            .setShouldRetryEagerInitializePrimaryAfterWarmInitFailure(true)
                    } else {
                        initializeCoordinator
                            .setShouldRetryEagerInitializePrimaryAfterWarmInitFailure(false)
                        startEagerInitializePrimary()
                    }
                }
                startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
            }
        }
    }

    package func assignUpstreamId(sessionId: String, originalId: RPCId, upstreamIndex: Int) -> Int64 {
        idMapper.assign(
            upstreamIndex: upstreamIndex, sessionId: sessionId, originalId: originalId,
            isInitialize: false)
    }

    package func removeUpstreamIdMapping(sessionId: String, requestIdKey: String, upstreamIndex: Int) {
        _ = idMapper.remove(
            upstreamIndex: upstreamIndex,
            sessionId: sessionId,
            requestIdKey: requestIdKey
        )
    }

    package func onRequestTimeout(sessionId: String, requestIdKey: String, upstreamIndex: Int) {
        removeUpstreamIdMapping(
            sessionId: sessionId, requestIdKey: requestIdKey, upstreamIndex: upstreamIndex)
        markRequestTimedOut(upstreamIndex: upstreamIndex)
    }

    package func onRequestSucceeded(sessionId: String, requestIdKey: String, upstreamIndex: Int) {
        _ = sessionId
        _ = requestIdKey
        markRequestSucceeded(upstreamIndex: upstreamIndex)
    }

    package func sendUpstream(_ data: Data, upstreamIndex: Int) {
        guard upstreamIndex >= 0, upstreamIndex < upstreams.count else {
            return
        }
        Task {
            let result = await upstreams[upstreamIndex].send(data)
            if result == .accepted {
                self.recordTraffic(
                    upstreamIndex: upstreamIndex,
                    direction: "outbound",
                    data: data
                )
                return
            }
            self.markUpstreamOverloaded(upstreamIndex: upstreamIndex)
            self.handleOverloadedUpstreamSend(
                originalRequestData: data,
                upstreamIndex: upstreamIndex
            )
        }
    }

    package func debugSnapshot() -> ProxyDebugSnapshot {
        let initSnapshot = initializeCoordinator.snapshot()
        let toolsSnapshot = toolsListCache.snapshot()
        let upstreamStates = upstreamPool.statesSnapshot()

        return debugRecorder.snapshot(
            proxyInitialized: initSnapshot.hasInitResult && !initSnapshot.isShuttingDown,
            cachedToolsListAvailable: toolsSnapshot.cachedResult != nil,
            warmupInFlight: toolsSnapshot.warmupInFlight,
            upstreamStates: upstreamStates,
            redactedText: Self.redactedDebugText,
            healthFormatter: upstreamPool.debugHealthStateString
        )
    }

    func testStateSnapshot() -> TestSnapshot {
        let initSnapshot = initializeCoordinator.snapshot()
        let upstreams = upstreamPool.statesSnapshot().map { upstream in
                TestSnapshot.Upstream(
                    isInitialized: upstream.isInitialized,
                    initInFlight: upstream.initInFlight,
                    healthState: upstream.healthState
                )
        }
        return TestSnapshot(
            hasInitResult: initSnapshot.hasInitResult,
            initInFlight: initSnapshot.initInFlight,
            didWarmSecondary: initSnapshot.didWarmSecondary,
            shouldRetryEagerInitializePrimaryAfterWarmInitFailure: initSnapshot
                .shouldRetryEagerInitializePrimaryAfterWarmInitFailure,
            upstreams: upstreams
        )
    }

    func testSessionSnapshot(id: String) -> TestSnapshot.Session? {
        sessionRegistry.testSnapshot(id: id)
    }

    func testSetInitializeRoutingState(
        sessionId: String,
        upstreamIndex: Int,
        preferOnNextPin: Bool,
        didReceiveInitializeUpstreamMessage: Bool = false
    ) {
        setInitializeUpstreamIndexIfNeeded(
            sessionId: sessionId,
            upstreamIndex: upstreamIndex,
            preferOnNextPin: preferOnNextPin
        )
        guard didReceiveInitializeUpstreamMessage else { return }
        sessionRegistry.markDidReceiveInitializeUpstreamMessage(for: sessionId)
    }

    func handleOverloadedUpstreamSend(
        originalRequestData: Data,
        upstreamIndex: Int
    ) {
        guard let any = try? JSONSerialization.jsonObject(with: originalRequestData, options: [])
        else {
            return
        }

        let overloadError: [String: Any] = [
            "code": -32002,
            "message": "upstream overloaded",
        ]

        let responseAny: Any? = {
            if let object = any as? [String: Any] {
                guard let id = object["id"], !(id is NSNull) else { return nil }
                return [
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": overloadError,
                ]
            }
            if let array = any as? [Any] {
                let objects = array.compactMap { item -> [String: Any]? in
                    guard let object = item as? [String: Any],
                        let id = object["id"],
                        !(id is NSNull)
                    else {
                        return nil
                    }
                    return [
                        "jsonrpc": "2.0",
                        "id": id,
                        "error": overloadError,
                    ]
                }
                if objects.isEmpty {
                    return nil
                }
                return objects
            }
            return nil
        }()

        guard let responseAny,
            JSONSerialization.isValidJSONObject(responseAny),
            let data = try? JSONSerialization.data(withJSONObject: responseAny, options: [])
        else {
            return
        }

        routeUpstreamMessage(data, upstreamIndex: upstreamIndex)
    }

    func upstreamId(from value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String, let number = Int64(string) {
            return number
        }
        return nil
    }

    func isServerInitiatedMessage(_ value: Any) -> Bool {
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

    func routeUnmappedUpstreamMessage(_ data: Data, upstreamIndex: Int) {
        recordTraffic(
            upstreamIndex: upstreamIndex,
            direction: "inbound_unmapped",
            data: data
        )
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []) else {
            logger.debug(
                "Dropping unmapped upstream message (invalid JSON)",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "bytes": .string("\(data.count)"),
                ]
            )
            return
        }

        let serverInitiatedPayloads: [Data] = {
            if let object = any as? [String: Any] {
                guard object["method"] is String else { return [] }
                return [data]
            }
            if let array = any as? [Any] {
                var payloads: [Data] = []
                payloads.reserveCapacity(array.count)
                for item in array {
                    guard let object = item as? [String: Any],
                        object["method"] is String,
                        JSONSerialization.isValidJSONObject(object),
                        let encoded = try? JSONSerialization.data(
                            withJSONObject: object, options: [])
                    else {
                        continue
                    }
                    payloads.append(encoded)
                }
                return payloads
            }
            return []
        }()

        guard !serverInitiatedPayloads.isEmpty else {
            logger.debug(
                "Dropping unmapped upstream response",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "bytes": .string("\(data.count)"),
                ]
            )
            return
        }

        let routedTargets = sessionRegistry.routedTargets(forUpstreamIndex: upstreamIndex)

        if !routedTargets.isEmpty {
            for payload in serverInitiatedPayloads {
                for session in routedTargets {
                    session.router.handleIncoming(payload)
                }
            }
            return
        }

        logger.debug(
            "Dropping unmapped upstream message (no routed target sessions)",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "bytes": .string("\(data.count)"),
            ]
        )
    }

    func handleUpstreamStderr(_ message: String, upstreamIndex: Int) {
        debugRecorder.recordStderr(message, upstreamIndex: upstreamIndex)
    }

    func handleUpstreamRecovery(_ recovery: StdioFramerRecovery, upstreamIndex: Int) {
        debugRecorder.recordRecovery(recovery, upstreamIndex: upstreamIndex)
    }

    func handleBufferedStdoutBytes(_ size: Int, upstreamIndex: Int) {
        debugRecorder.recordBufferedStdoutBytes(size, upstreamIndex: upstreamIndex)
    }

    func recordTraffic(
        upstreamIndex: Int,
        direction: String,
        data: Data
    ) {
        debugRecorder.recordTraffic(
            upstreamIndex: upstreamIndex,
            direction: direction,
            data: data,
            redactedText: Self.redactedDebugText
        )
    }
}
