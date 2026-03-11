import Foundation
import NIOConcurrencyHelpers
import ProxyCore

package final class ProxyDebugRecorder: Sendable {
    private struct DebugUpstreamState: Sendable {
        var recentStderr: [ProxyDebugEvent] = []
        var lastDecodeError: ProxyDebugEvent?
        var lastBridgeError: ProxyDebugEvent?
        var resyncCount = 0
        var lastResyncAt: Date?
        var lastResyncDroppedBytes: Int?
        var lastResyncPreview: String?
        var bufferedStdoutBytes = 0
    }

    private struct State: Sendable {
        var upstreams: [DebugUpstreamState] = []
        var recentTraffic: [ProxyDebugTrafficEvent] = []
    }

    private let state = NIOLockedValueBox(State())
    private let trafficLimit: Int
    private let stderrLimit: Int

    package init(
        upstreamCount: Int,
        trafficLimit: Int = 50,
        stderrLimit: Int = 20
    ) {
        self.trafficLimit = trafficLimit
        self.stderrLimit = stderrLimit
        state.withLockedValue { state in
            state.upstreams = Array(repeating: DebugUpstreamState(), count: upstreamCount)
            state.recentTraffic = []
        }
    }

    package func resetUpstream(_ upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreams.count else { return }
            state.upstreams[upstreamIndex] = DebugUpstreamState()
        }
    }

    package func recordStderr(_ message: String, upstreamIndex: Int) {
        let event = ProxyDebugEvent(timestamp: Date(), message: message)
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreams.count else { return }
            state.upstreams[upstreamIndex].recentStderr.append(event)
            if state.upstreams[upstreamIndex].recentStderr.count > stderrLimit {
                state.upstreams[upstreamIndex].recentStderr.removeFirst(
                    state.upstreams[upstreamIndex].recentStderr.count - stderrLimit
                )
            }
            if message.contains("Could not decode agent message") {
                state.upstreams[upstreamIndex].lastDecodeError = event
            }
            if message.contains("BridgeError") {
                state.upstreams[upstreamIndex].lastBridgeError = event
            }
        }
    }

    package func recordRecovery(_ recovery: StdioFramerRecovery, upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreams.count else { return }
            state.upstreams[upstreamIndex].resyncCount += 1
            state.upstreams[upstreamIndex].lastResyncAt = Date()
            state.upstreams[upstreamIndex].lastResyncDroppedBytes = recovery.droppedPrefixBytes
            if let recovered = recovery.previewRecoveredMessage, !recovered.isEmpty {
                state.upstreams[upstreamIndex].lastResyncPreview = recovered
            } else {
                state.upstreams[upstreamIndex].lastResyncPreview = recovery.previewBeforeDrop
            }
        }
    }

    package func recordBufferedStdoutBytes(_ size: Int, upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreams.count else { return }
            state.upstreams[upstreamIndex].bufferedStdoutBytes = size
        }
    }

    package func recordTraffic(upstreamIndex: Int, direction: String, data: Data, redactedText: String) {
        let event = ProxyDebugTrafficEvent(
            timestamp: Date(),
            upstreamIndex: upstreamIndex,
            direction: direction,
            bytes: data.count,
            preview: redactedText
        )
        state.withLockedValue { state in
            state.recentTraffic.append(event)
            if state.recentTraffic.count > trafficLimit {
                state.recentTraffic.removeFirst(state.recentTraffic.count - trafficLimit)
            }
        }
    }

    package func snapshot(
        proxyInitialized: Bool,
        cachedToolsListAvailable: Bool,
        warmupInFlight: Bool,
        upstreamStates: [UpstreamSelectionPolicy.UpstreamState],
        redactedText: String,
        healthFormatter: (UpstreamHealthState) -> String
    ) -> ProxyDebugSnapshot {
        let recordedState = state.withLockedValue { state in
            (upstreams: state.upstreams, recentTraffic: state.recentTraffic)
        }

        let upstreamSnapshots = upstreamStates.enumerated().map { index, upstream in
            let debug = index < recordedState.upstreams.count ? recordedState.upstreams[index] : DebugUpstreamState()
            return ProxyUpstreamDebugSnapshot(
                upstreamIndex: index,
                isInitialized: upstream.isInitialized,
                initInFlight: upstream.initInFlight,
                didSendInitialized: upstream.didSendInitialized,
                healthState: healthFormatter(upstream.healthState),
                consecutiveRequestTimeouts: upstream.consecutiveRequestTimeouts,
                consecutiveToolsListFailures: upstream.consecutiveToolsListFailures,
                lastToolsListSuccessUptimeNs: upstream.lastToolsListSuccessUptimeNs,
                recentStderr: debug.recentStderr.map { event in
                    ProxyDebugEvent(timestamp: event.timestamp, message: redactedText)
                },
                lastDecodeError: debug.lastDecodeError.map {
                    ProxyDebugEvent(timestamp: $0.timestamp, message: redactedText)
                },
                lastBridgeError: debug.lastBridgeError.map {
                    ProxyDebugEvent(timestamp: $0.timestamp, message: redactedText)
                },
                resyncCount: debug.resyncCount,
                lastResyncAt: debug.lastResyncAt,
                lastResyncDroppedBytes: debug.lastResyncDroppedBytes,
                lastResyncPreview: debug.lastResyncPreview.map { _ in redactedText },
                bufferedStdoutBytes: debug.bufferedStdoutBytes
            )
        }

        return ProxyDebugSnapshot(
            generatedAt: Date(),
            proxyInitialized: proxyInitialized,
            cachedToolsListAvailable: cachedToolsListAvailable,
            warmupInFlight: warmupInFlight,
            upstreams: upstreamSnapshots,
            recentTraffic: recordedState.recentTraffic.map {
                ProxyDebugTrafficEvent(
                    timestamp: $0.timestamp,
                    upstreamIndex: $0.upstreamIndex,
                    direction: $0.direction,
                    bytes: $0.bytes,
                    preview: redactedText
                )
            }
        )
    }
}
