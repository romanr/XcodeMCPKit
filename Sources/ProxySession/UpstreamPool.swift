import Foundation
import NIO
import NIOConcurrencyHelpers
import ProxyUpstream

package struct HealthProbeRequest: Sendable {
    package let upstreamIndex: Int
    package let probeGeneration: UInt64
}

package final class UpstreamPool: Sendable {
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

    private struct State: Sendable {
        var upstreamStates: [UpstreamState] = []
        var nextPick: Int = 0
    }

    private let state: NIOLockedValueBox<State>

    package init(upstreamCount: Int) {
        self.state = NIOLockedValueBox(State(
            upstreamStates: Array(repeating: UpstreamState(), count: upstreamCount),
            nextPick: 0
        ))
    }

    package func statesSnapshot() -> [UpstreamState] {
        state.withLockedValue { $0.upstreamStates }
    }

    package func count() -> Int {
        state.withLockedValue { $0.upstreamStates.count }
    }

    package func clearInitTimeoutsForShutdown() -> [Scheduled<Void>?] {
        state.withLockedValue { state -> [Scheduled<Void>?] in
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
    }

    package func anyInitialized() -> Bool {
        state.withLockedValue { $0.upstreamStates.contains { $0.isInitialized } }
    }

    package func primaryInitInFlight() -> Bool {
        state.withLockedValue { state in
            guard !state.upstreamStates.isEmpty else { return false }
            return state.upstreamStates[0].initInFlight
        }
    }

    package func initializedHealthyishCount() -> Int {
        state.withLockedValue { state in
            state.upstreamStates.reduce(into: 0) { count, upstream in
                guard upstream.isInitialized else { return }
                switch upstream.healthState {
                case .healthy, .degraded:
                    count += 1
                case .quarantined:
                    break
                }
            }
        }
    }

    package func evaluateUsableInitialized(index: Int, nowUptimeNs: UInt64) -> (Bool, [HealthProbeRequest]) {
        var probes: [HealthProbeRequest] = []
        let usable = state.withLockedValue { state in
            guard index >= 0, index < state.upstreamStates.count else { return false }
            let health = Self.classifyHealthAndCollectProbeIfNeeded(
                upstreamIndex: index,
                nowUptimeNs: nowUptimeNs,
                state: &state,
                probesToStart: &probes
            )
            let isHealthyEnough: Bool
            switch health {
            case .healthy, .degraded:
                isHealthyEnough = true
            case .quarantined:
                isHealthyEnough = false
            }
            return isHealthyEnough && state.upstreamStates[index].isInitialized
        }
        return (usable, probes)
    }

    package func chooseBestInitializedUpstream(nowUptimeNs: UInt64) -> (Int?, [HealthProbeRequest]) {
        var probes: [HealthProbeRequest] = []
        let chosen = state.withLockedValue { state -> Int? in
            let count = state.upstreamStates.count
            guard count > 0 else { return nil }

            let rawStart = state.nextPick % count
            let start = rawStart >= 0 ? rawStart : rawStart + count
            state.nextPick &+= 1

            var degradedCandidate: Int?
            for offset in 0..<count {
                let candidate = (start + offset) % count
                guard state.upstreamStates[candidate].isInitialized else { continue }
                let health = Self.classifyHealthAndCollectProbeIfNeeded(
                    upstreamIndex: candidate,
                    nowUptimeNs: nowUptimeNs,
                    state: &state,
                    probesToStart: &probes
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
        return (chosen, probes)
    }

    package func markRequestSucceeded(upstreamIndex: Int) {
        state.withLockedValue { state in
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

    package func markUpstreamOverloaded(upstreamIndex: Int) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return false }

            if case .healthy = state.upstreamStates[upstreamIndex].healthState {
                state.upstreamStates[upstreamIndex].healthState = .degraded
            }

            if state.upstreamStates[upstreamIndex].healthProbeInFlight {
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            } else {
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            }
            return true
        }
    }

    package func markRequestTimedOut(upstreamIndex: Int, nowUptimeNs: UInt64) -> (shouldClearPins: Bool, timeoutCount: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else {
                return (false, 0)
            }
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts += 1
            let timeoutCount = state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts
            if timeoutCount >= 3 {
                let quarantineUntil = nowUptimeNs &+ 15_000_000_000
                state.upstreamStates[upstreamIndex].healthState = .quarantined(untilUptimeNs: quarantineUntil)
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                return (true, timeoutCount)
            } else {
                state.upstreamStates[upstreamIndex].healthState = .degraded
                return (false, timeoutCount)
            }
        }
    }

    package func finishHealthProbe(
        upstreamIndex: Int,
        probeGeneration: UInt64,
        success: Bool,
        nowUptimeNs: UInt64
    ) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            guard state.upstreamStates[upstreamIndex].healthProbeGeneration == probeGeneration else { return }
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
    }

    package func markToolsListRefreshSucceeded(upstreamIndex: Int, nowUptimeNs: UInt64) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].healthState = .healthy
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures = 0
            state.upstreamStates[upstreamIndex].lastToolsListSuccessUptimeNs = nowUptimeNs
        }
    }

    package func markToolsListRefreshFailed(upstreamIndex: Int, nowUptimeNs: UInt64) -> (failures: Int, quarantineUntil: UInt64)? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let quarantineUntil = nowUptimeNs &+ 30 * 1_000_000_000
            state.upstreamStates[upstreamIndex].healthState = .quarantined(untilUptimeNs: quarantineUntil)
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures += 1
            return (state.upstreamStates[upstreamIndex].consecutiveToolsListFailures, quarantineUntil)
        }
    }

    package func markDidSendInitializedIfNeeded(upstreamIndex: Int) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else {
                return false
            }
            if state.upstreamStates[upstreamIndex].didSendInitialized {
                return false
            }
            state.upstreamStates[upstreamIndex].didSendInitialized = true
            return true
        }
    }

    package func beginWarmInitialize(upstreamIndex: Int) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return false }
            if state.upstreamStates[upstreamIndex].isInitialized || state.upstreamStates[upstreamIndex].initInFlight {
                return false
            }
            state.upstreamStates[upstreamIndex].initInFlight = true
            return true
        }
    }

    package func setWarmInitializeUpstreamId(_ upstreamId: Int64, for upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initUpstreamId = upstreamId
        }
    }

    package func replaceInitTimeout(_ timeout: Scheduled<Void>, upstreamIndex: Int) -> Scheduled<Void>? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let existing = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = timeout
            return existing
        }
    }

    package func clearWarmInitializeIfMatching(upstreamIndex: Int, upstreamId: Int64) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return false }
            guard state.upstreamStates[upstreamIndex].initUpstreamId == upstreamId else { return false }
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].isInitialized = false
            state.upstreamStates[upstreamIndex].initUpstreamId = nil
            return true
        }
    }

    package func markInitInFlight(upstreamIndex: Int, upstreamId: Int64) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initInFlight = true
            state.upstreamStates[upstreamIndex].initUpstreamId = upstreamId
            state.upstreamStates[upstreamIndex].isInitialized = false
        }
    }

    package func clearInitInFlight(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initUpstreamId = nil
            state.upstreamStates[upstreamIndex].initTimeout = nil
        }
    }

    package func clearUpstreamState(upstreamIndex: Int) -> Scheduled<Void>? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let timeout = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].isInitialized = false
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].didSendInitialized = false
            state.upstreamStates[upstreamIndex].initUpstreamId = nil
            state.upstreamStates[upstreamIndex].healthState = .healthy
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures = 0
            state.upstreamStates[upstreamIndex].lastToolsListSuccessUptimeNs = nil
            return timeout
        }
    }

    package func markInitialized(upstreamIndex: Int) -> Scheduled<Void>? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            state.upstreamStates[upstreamIndex].isInitialized = true
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initUpstreamId = nil
            state.upstreamStates[upstreamIndex].healthState = .healthy
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            let timeout = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = nil
            return timeout
        }
    }

    package func debugHealthStateString(_ state: UpstreamHealthState) -> String {
        switch state {
        case .healthy:
            return "healthy"
        case .degraded:
            return "degraded"
        case .quarantined(let untilUptimeNs):
            return "quarantined(untilUptimeNs:\(untilUptimeNs))"
        }
    }

    private static func classifyHealthAndCollectProbeIfNeeded(
        upstreamIndex: Int,
        nowUptimeNs: UInt64,
        state: inout State,
        probesToStart: inout [HealthProbeRequest]
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
                    HealthProbeRequest(
                        upstreamIndex: upstreamIndex,
                        probeGeneration: state.upstreamStates[upstreamIndex].healthProbeGeneration
                    )
                )
            }
            return .quarantined(untilUptimeNs: untilUptimeNs)
        }
    }
}
