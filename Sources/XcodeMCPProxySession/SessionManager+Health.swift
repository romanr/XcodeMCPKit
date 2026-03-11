import Foundation
import NIO
import NIOFoundationCompat
import XcodeMCPProxyCore
import XcodeMCPProxyUpstream

extension SessionManager {
    func clearPinnedSessions(forUpstreamIndex upstreamIndex: Int) -> Int {
        sessionsState.withLockedValue { state -> Int in
            let keys = Array(state.sessions.keys)
            var cleared = 0
            for key in keys {
                if state.sessions[key]?.pinnedUpstreamIndex == upstreamIndex {
                    state.sessions[key]?.pinnedUpstreamIndex = nil
                    state.sessions[key]?.initializeUpstreamIndex = nil
                    state.sessions[key]?.preferInitializeUpstreamOnNextPin = false
                    cleared += 1
                } else if state.sessions[key]?.initializeUpstreamIndex == upstreamIndex {
                    state.sessions[key]?.initializeUpstreamIndex = nil
                    state.sessions[key]?.preferInitializeUpstreamOnNextPin = false
                }
            }
            return cleared
        }
    }

    func markRequestSucceeded(upstreamIndex: Int) {
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].healthState = .healthy
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            if state.upstreamStates[upstreamIndex].healthProbeInFlight {
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            } else {
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            }
        }
    }

    func markUpstreamOverloaded(upstreamIndex: Int) {
        var shouldClearPins = false
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }

            if case .healthy = state.upstreamStates[upstreamIndex].healthState {
                state.upstreamStates[upstreamIndex].healthState = .degraded
            }

            if state.upstreamStates[upstreamIndex].healthProbeInFlight {
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            } else {
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            }
            shouldClearPins = true
        }

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
        var shouldClearPins = false
        var timeoutCount = 0
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts += 1
            timeoutCount = state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts
            if timeoutCount >= 3 {
                let quarantineUntil = nowUptimeNs &+ 15_000_000_000
                state.upstreamStates[upstreamIndex].healthState = .quarantined(
                    untilUptimeNs: quarantineUntil)
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                shouldClearPins = true
            } else {
                state.upstreamStates[upstreamIndex].healthState = .degraded
            }
        }

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
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            guard state.upstreamStates[upstreamIndex].healthProbeGeneration == probeGeneration
            else {
                return
            }
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            if success {
                state.upstreamStates[upstreamIndex].healthState = .healthy
                state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            } else {
                state.upstreamStates[upstreamIndex].healthState = .quarantined(
                    untilUptimeNs: nowUptimeNs &+ 15_000_000_000
                )
            }
        }
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
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].healthState = .healthy
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures = 0
            state.upstreamStates[upstreamIndex].lastToolsListSuccessUptimeNs = nowUptimeNs
        }
    }

    func markToolsListRefreshFailed(upstreamIndex: Int, nowUptimeNs: UInt64, reason: String)
    {
        let quarantineNs: UInt64 = 30 * 1_000_000_000
        let quarantineUntil = nowUptimeNs &+ quarantineNs

        var failures = 0
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].healthState = .quarantined(
                untilUptimeNs: quarantineUntil)
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures += 1
            failures = state.upstreamStates[upstreamIndex].consecutiveToolsListFailures
        }

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
            toolsListState.withLockedValue { $0.warmupInFlight = false }
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
        var shouldSend = false
        var upstreamId: Int64?
        upstreamState.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            if state.upstreamStates[upstreamIndex].isInitialized
                || state.upstreamStates[upstreamIndex].initInFlight
            {
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
        let previous = upstreamState.withLockedValue { state -> Scheduled<Void>? in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let existing = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = timeout
            return existing
        }
        previous?.cancel()
    }

    func handleUpstreamInitTimeout(upstreamIndex: Int, upstreamId: Int64) {
        let shouldClear = upstreamState.withLockedValue { state -> Bool in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else {
                return false
            }
            guard state.upstreamStates[upstreamIndex].initUpstreamId == upstreamId else {
                return false
            }
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
