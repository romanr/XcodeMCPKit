import Foundation
import NIOConcurrencyHelpers
import ProxyCore

extension RuntimeCoordinator {
    static func makeDefaultUpstreams(
        config: ProxyConfig,
        sharedSessionID: String?,
        count: Int
    ) -> [UpstreamProcess] {
        var environment = ProcessInfo.processInfo.environment
        if let pid = config.xcodePID {
            environment["MCP_XCODE_PID"] = String(pid)
        }
        if let sharedSessionID, !sharedSessionID.isEmpty {
            environment["MCP_XCODE_SESSION_ID"] = sharedSessionID
        } else {
            environment.removeValue(forKey: "MCP_XCODE_SESSION_ID")
        }
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

package final class ResponseCorrelationStore: Sendable {
    private struct RequestLookupKey: Hashable, Sendable {
        let sessionID: String
        let requestIDKey: String
    }

    private struct State: Sendable {
        var nextID: Int64 = 1
        var mappingsByUpstream: [[Int64: UpstreamMapping]] = []
        var upstreamIDByRequestKeyByUpstream: [[RequestLookupKey: Int64]] = []
    }

    private let state = NIOLockedValueBox(State())

    init(upstreamCount: Int) {
        state.withLockedValue { state in
            state.mappingsByUpstream = Array(repeating: [:], count: upstreamCount)
            state.upstreamIDByRequestKeyByUpstream = Array(repeating: [:], count: upstreamCount)
        }
    }

    func assign(upstreamIndex: Int, sessionID: String, originalID: RPCID, isInitialize: Bool)
        -> Int64
    {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return 0
            }
            let id = state.nextID
            state.nextID += 1
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamMapping(
                sessionID: sessionID,
                originalID: originalID,
                isInitialize: isInitialize
            )
            if isInitialize == false {
                let requestKey = Self.requestLookupKey(
                    sessionID: sessionID, requestIDKey: originalID.key)
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex][requestKey] = id
            }
            return id
        }
    }

    func assignInitialize(upstreamIndex: Int) -> Int64 {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return 0
            }
            let id = state.nextID
            state.nextID += 1
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamMapping(
                sessionID: nil,
                originalID: nil,
                isInitialize: true
            )
            return id
        }
    }

    func consume(upstreamIndex: Int, upstreamID: Int64) -> UpstreamMapping? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return nil
            }
            let mapping = state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamID)
            if let mapping,
                let sessionID = mapping.sessionID,
                let originalID = mapping.originalID
            {
                let requestKey = Self.requestLookupKey(
                    sessionID: sessionID, requestIDKey: originalID.key)
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            }
            return mapping
        }
    }

    func remove(upstreamIndex: Int, upstreamID: Int64) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return }
            let mapping = state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamID)
            if let mapping,
                let sessionID = mapping.sessionID,
                let originalID = mapping.originalID
            {
                let requestKey = Self.requestLookupKey(
                    sessionID: sessionID, requestIDKey: originalID.key)
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            }
        }
    }

    func remove(
        upstreamIndex: Int,
        sessionID: String,
        requestIDKey: String
    ) -> Int64? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return nil
            }
            let requestKey = Self.requestLookupKey(sessionID: sessionID, requestIDKey: requestIDKey)
            guard
                let upstreamID = state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            else {
                return nil
            }
            state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamID)
            return upstreamID
        }
    }

    func reset(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return }
            state.mappingsByUpstream[upstreamIndex].removeAll()
            state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeAll()
        }
    }

    private static func requestLookupKey(sessionID: String, requestIDKey: String)
        -> RequestLookupKey
    {
        RequestLookupKey(sessionID: sessionID, requestIDKey: requestIDKey)
    }
}

package struct UpstreamMapping: Sendable {
    package let sessionID: String?
    package let originalID: RPCID?
    package let isInitialize: Bool
}
