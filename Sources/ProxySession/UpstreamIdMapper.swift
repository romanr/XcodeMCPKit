import Foundation
import NIOConcurrencyHelpers
import ProxyCore
import ProxyUpstream

extension SessionManager {
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
            restartMaxDelay: 30,
            maxQueuedWriteBytes: {
                let minimum = 1_048_576
                guard config.maxBodyBytes > 0 else { return minimum }
                let multiplied = config.maxBodyBytes.multipliedReportingOverflow(by: 4)
                if multiplied.overflow {
                    return Int.max
                }
                return max(minimum, multiplied.partialValue)
            }()
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

package final class UpstreamIdMapper: Sendable {
    private struct RequestLookupKey: Hashable, Sendable {
        let sessionId: String
        let requestIdKey: String
    }

    private struct State: Sendable {
        var nextId: Int64 = 1
        var mappingsByUpstream: [[Int64: UpstreamMapping]] = []
        var upstreamIdByRequestKeyByUpstream: [[RequestLookupKey: Int64]] = []
    }

    private let state = NIOLockedValueBox(State())

    init(upstreamCount: Int) {
        state.withLockedValue { state in
            state.mappingsByUpstream = Array(repeating: [:], count: upstreamCount)
            state.upstreamIdByRequestKeyByUpstream = Array(repeating: [:], count: upstreamCount)
        }
    }

    func assign(upstreamIndex: Int, sessionId: String, originalId: RPCId, isInitialize: Bool)
        -> Int64
    {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return 0
            }
            let id = state.nextId
            state.nextId += 1
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamMapping(
                sessionId: sessionId,
                originalId: originalId,
                isInitialize: isInitialize
            )
            if isInitialize == false {
                let requestKey = Self.requestLookupKey(
                    sessionId: sessionId, requestIdKey: originalId.key)
                state.upstreamIdByRequestKeyByUpstream[upstreamIndex][requestKey] = id
            }
            return id
        }
    }

    func assignInitialize(upstreamIndex: Int) -> Int64 {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return 0
            }
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
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return nil
            }
            let mapping = state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamId)
            if let mapping,
                let sessionId = mapping.sessionId,
                let originalId = mapping.originalId
            {
                let requestKey = Self.requestLookupKey(
                    sessionId: sessionId, requestIdKey: originalId.key)
                state.upstreamIdByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            }
            return mapping
        }
    }

    func remove(upstreamIndex: Int, upstreamId: Int64) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return }
            let mapping = state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamId)
            if let mapping,
                let sessionId = mapping.sessionId,
                let originalId = mapping.originalId
            {
                let requestKey = Self.requestLookupKey(
                    sessionId: sessionId, requestIdKey: originalId.key)
                state.upstreamIdByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            }
        }
    }

    func remove(
        upstreamIndex: Int,
        sessionId: String,
        requestIdKey: String
    ) -> Int64? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return nil
            }
            let requestKey = Self.requestLookupKey(sessionId: sessionId, requestIdKey: requestIdKey)
            guard
                let upstreamId = state.upstreamIdByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            else {
                return nil
            }
            state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamId)
            return upstreamId
        }
    }

    func reset(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return }
            state.mappingsByUpstream[upstreamIndex].removeAll()
            state.upstreamIdByRequestKeyByUpstream[upstreamIndex].removeAll()
        }
    }

    private static func requestLookupKey(sessionId: String, requestIdKey: String)
        -> RequestLookupKey
    {
        RequestLookupKey(sessionId: sessionId, requestIdKey: requestIdKey)
    }
}

package struct UpstreamMapping: Sendable {
    package let sessionId: String?
    package let originalId: RPCId?
    package let isInitialize: Bool
}
