import Foundation
import NIO
import NIOFoundationCompat
import ProxyCore
import ProxyUpstream

extension SessionManager {
    func clearPinnedSessions(forUpstreamIndex upstreamIndex: Int) -> Int {
        sessionRegistry.clearPinnedSessions(forUpstreamIndex: upstreamIndex)
    }

    func markRequestSucceeded(upstreamIndex: Int) {
        upstreamPool.markRequestSucceeded(upstreamIndex: upstreamIndex)
    }

    func markUpstreamOverloaded(upstreamIndex: Int) {
        let shouldClearPins = upstreamPool.markUpstreamOverloaded(upstreamIndex: upstreamIndex)

        guard shouldClearPins else { return }
        let cleared = clearPinnedSessions(forUpstreamIndex: upstreamIndex)
        if cleared > 0 {
            logger.warning(
                "Upstream overloaded; cleared pinned sessions for failover",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "cleared_pins": .string("\(cleared)"),
                ]
            )
        }
    }

    func markRequestTimedOut(upstreamIndex: Int) {
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        let result = upstreamPool.markRequestTimedOut(
            upstreamIndex: upstreamIndex,
            nowUptimeNs: nowUptimeNs
        )
        let shouldClearPins = result.shouldClearPins
        let timeoutCount = result.timeoutCount

        if shouldClearPins {
            let cleared = clearPinnedSessions(forUpstreamIndex: upstreamIndex)
            logger.warning(
                "Upstream quarantined after repeated request timeouts",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "timeout_count": .string("\(timeoutCount)"),
                    "cleared_pins": .string("\(cleared)"),
                ]
            )
        }
    }

    func probeUpstreamHealth(upstreamIndex: Int, probeGeneration: UInt64) {
        let internalSessionId = toolsListInternalSessionId()
        _ = session(id: internalSessionId)
        let probeSession = session(id: internalSessionId)
        let probeTimeout: TimeAmount = .seconds(2)
        let originalId = RPCId(any: "__probe-\(upstreamIndex)-\(UUID().uuidString)")!
        let future = probeSession.router.registerRequest(
            idKey: originalId.key,
            on: eventLoop,
            timeout: probeTimeout
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
            let requestData = try? JSONSerialization.data(withJSONObject: request, options: [])
        else {
            finishHealthProbe(
                upstreamIndex: upstreamIndex,
                probeGeneration: probeGeneration,
                success: false,
                reason: "encode_request_failed"
            )
            return
        }

        sendUpstream(requestData, upstreamIndex: upstreamIndex)

        Task { [weak self] in
            guard let self else { return }
            do {
                var buffer = try await future.get()
                guard let responseData = buffer.readData(length: buffer.readableBytes),
                    let object = try JSONSerialization.jsonObject(with: responseData, options: [])
                        as? [String: Any],
                    object["error"] == nil,
                    object["result"] != nil
                else {
                    self.idMapper.remove(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
                    self.finishHealthProbe(
                        upstreamIndex: upstreamIndex,
                        probeGeneration: probeGeneration,
                        success: false,
                        reason: "invalid_response"
                    )
                    return
                }
                self.finishHealthProbe(
                    upstreamIndex: upstreamIndex,
                    probeGeneration: probeGeneration,
                    success: true,
                    reason: "ok"
                )
            } catch {
                self.idMapper.remove(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
                self.finishHealthProbe(
                    upstreamIndex: upstreamIndex,
                    probeGeneration: probeGeneration,
                    success: false,
                    reason: "timeout"
                )
            }
        }
    }

    func finishHealthProbe(
        upstreamIndex: Int,
        probeGeneration: UInt64,
        success: Bool,
        reason: String
    ) {
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        upstreamPool.finishHealthProbe(
            upstreamIndex: upstreamIndex,
            probeGeneration: probeGeneration,
            success: success,
            nowUptimeNs: nowUptimeNs
        )
        logger.debug(
            "Upstream health probe completed",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "success": .string(success ? "true" : "false"),
                "reason": .string(reason),
            ]
        )
    }

    func markToolsListRefreshSucceeded(upstreamIndex: Int, nowUptimeNs: UInt64) {
        upstreamPool.markToolsListRefreshSucceeded(upstreamIndex: upstreamIndex, nowUptimeNs: nowUptimeNs)
    }

    func markToolsListRefreshFailed(upstreamIndex: Int, nowUptimeNs: UInt64, reason: String)
    {
        guard let result = upstreamPool.markToolsListRefreshFailed(
            upstreamIndex: upstreamIndex,
            nowUptimeNs: nowUptimeNs
        ) else { return }
        let failures = result.failures
        let quarantineUntil = result.quarantineUntil

        logger.debug(
            "tools/list warmup failed (best-effort)",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "reason": .string(reason),
                "failures": .string("\(failures)"),
                "quarantine_until_uptime_ns": .string("\(quarantineUntil)"),
                "uptime_ns": .string("\(nowUptimeNs)"),
            ]
        )
    }

    func refreshToolsList() async {
        defer {
            toolsListCache.endWarmup()
        }

        let refreshTimeout: TimeAmount = .seconds(5)
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
        let internalSessionId = toolsListInternalSessionId()
        _ = session(id: internalSessionId)

        guard
            let upstreamIndex = chooseUpstreamIndex(sessionId: internalSessionId, shouldPin: false),
            upstreamIndex >= 0,
            upstreamIndex < upstreams.count
        else {
            logger.debug("tools/list refresh: no available upstream")
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
            let requestData = try? JSONSerialization.data(withJSONObject: request, options: [])
        else {
            idMapper.remove(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
            markToolsListRefreshFailed(
                upstreamIndex: upstreamIndex, nowUptimeNs: nowUptimeNs,
                reason: "encode_request_failed")
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
                let response = try JSONSerialization.jsonObject(with: responseData, options: [])
                    as? [String: Any],
                let resultAny = response["result"],
                let result = JSONValue(any: resultAny),
                isValidToolsListResult(result)
            else {
                idMapper.remove(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
                markToolsListRefreshFailed(
                    upstreamIndex: upstreamIndex, nowUptimeNs: nowUptimeNs,
                    reason: "invalid_response")
                return
            }

            markToolsListRefreshSucceeded(upstreamIndex: upstreamIndex, nowUptimeNs: nowUptimeNs)
            setCachedToolsListResult(result)
            logger.debug(
                "tools/list refresh succeeded",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "bytes": .string("\(responseData.count)"),
                ]
            )
        } catch {
            idMapper.remove(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
            markToolsListRefreshFailed(
                upstreamIndex: upstreamIndex, nowUptimeNs: nowUptimeNs, reason: "timeout")
        }
    }

    func isValidToolsListResult(_ value: JSONValue) -> Bool {
        guard case .object(let object) = value else { return false }
        guard let toolsValue = object["tools"] else { return false }
        if case .array = toolsValue {
            return true
        }
        return false
    }

    func startUpstreamWarmInitialize(upstreamIndex: Int) {
        guard upstreamPool.beginWarmInitialize(upstreamIndex: upstreamIndex) else { return }

        let upstreamId = idMapper.assignInitialize(upstreamIndex: upstreamIndex)
        upstreamPool.setWarmInitializeUpstreamId(upstreamId, for: upstreamIndex)
        scheduleUpstreamInitTimeout(upstreamIndex: upstreamIndex, upstreamId: upstreamId)

        let request = makeInternalInitializeRequest(id: upstreamId)
        if let data = try? JSONSerialization.data(withJSONObject: request, options: []) {
            sendUpstream(data, upstreamIndex: upstreamIndex)
        } else {
            clearUpstreamState(upstreamIndex: upstreamIndex)
        }
    }

    func scheduleUpstreamInitTimeout(upstreamIndex: Int, upstreamId: Int64) {
        guard
            let timeoutAmount = MCPMethodDispatcher.timeoutForInitialize(
                defaultSeconds: config.requestTimeout)
        else {
            return
        }
        let timeout = eventLoop.scheduleTask(in: timeoutAmount) { [weak self] in
            guard let self else { return }
            self.handleUpstreamInitTimeout(upstreamIndex: upstreamIndex, upstreamId: upstreamId)
        }
        let previous = upstreamPool.replaceInitTimeout(timeout, upstreamIndex: upstreamIndex)
        previous?.cancel()
    }

    func handleUpstreamInitTimeout(upstreamIndex: Int, upstreamId: Int64) {
        let shouldClear = upstreamPool.clearWarmInitializeIfMatching(
            upstreamIndex: upstreamIndex,
            upstreamId: upstreamId
        )
        guard shouldClear else { return }
        idMapper.remove(upstreamIndex: upstreamIndex, upstreamId: upstreamId)

        guard upstreamIndex == 0, config.eagerInitialize else { return }
        let shouldRetryEagerInit = initState.withLockedValue { state -> Bool in
            let shouldRetry =
                state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure
                && state.initResult == nil
            if shouldRetry {
                state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
            }
            return shouldRetry
        }
        if shouldRetryEagerInit {
            startEagerInitializePrimary()
        }
    }
}
