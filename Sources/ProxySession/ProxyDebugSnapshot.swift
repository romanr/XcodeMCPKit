import Foundation

package struct ProxyDebugEvent: Codable, Sendable {
    package let timestamp: Date
    package let message: String

    package init(timestamp: Date, message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

package struct ProxyDebugTrafficEvent: Codable, Sendable {
    package let timestamp: Date
    package let upstreamIndex: Int
    package let direction: String
    package let bytes: Int
    package let preview: String

    package init(timestamp: Date, upstreamIndex: Int, direction: String, bytes: Int, preview: String) {
        self.timestamp = timestamp
        self.upstreamIndex = upstreamIndex
        self.direction = direction
        self.bytes = bytes
        self.preview = preview
    }
}

package struct ProxyUpstreamDebugSnapshot: Codable, Sendable {
    package let upstreamIndex: Int
    package let isInitialized: Bool
    package let initInFlight: Bool
    package let didSendInitialized: Bool
    package let healthState: String
    package let consecutiveRequestTimeouts: Int
    package let consecutiveToolsListFailures: Int
    package let lastToolsListSuccessUptimeNs: UInt64?
    package let recentStderr: [ProxyDebugEvent]
    package let lastDecodeError: ProxyDebugEvent?
    package let lastBridgeError: ProxyDebugEvent?
    package let resyncCount: Int
    package let lastResyncAt: Date?
    package let lastResyncDroppedBytes: Int?
    package let lastResyncPreview: String?
    package let bufferedStdoutBytes: Int

    package init(
        upstreamIndex: Int,
        isInitialized: Bool,
        initInFlight: Bool,
        didSendInitialized: Bool,
        healthState: String,
        consecutiveRequestTimeouts: Int,
        consecutiveToolsListFailures: Int,
        lastToolsListSuccessUptimeNs: UInt64?,
        recentStderr: [ProxyDebugEvent],
        lastDecodeError: ProxyDebugEvent?,
        lastBridgeError: ProxyDebugEvent?,
        resyncCount: Int,
        lastResyncAt: Date?,
        lastResyncDroppedBytes: Int?,
        lastResyncPreview: String?,
        bufferedStdoutBytes: Int
    ) {
        self.upstreamIndex = upstreamIndex
        self.isInitialized = isInitialized
        self.initInFlight = initInFlight
        self.didSendInitialized = didSendInitialized
        self.healthState = healthState
        self.consecutiveRequestTimeouts = consecutiveRequestTimeouts
        self.consecutiveToolsListFailures = consecutiveToolsListFailures
        self.lastToolsListSuccessUptimeNs = lastToolsListSuccessUptimeNs
        self.recentStderr = recentStderr
        self.lastDecodeError = lastDecodeError
        self.lastBridgeError = lastBridgeError
        self.resyncCount = resyncCount
        self.lastResyncAt = lastResyncAt
        self.lastResyncDroppedBytes = lastResyncDroppedBytes
        self.lastResyncPreview = lastResyncPreview
        self.bufferedStdoutBytes = bufferedStdoutBytes
    }
}

package struct ProxyDebugSnapshot: Codable, Sendable {
    package let generatedAt: Date
    package let proxyInitialized: Bool
    package let cachedToolsListAvailable: Bool
    package let warmupInFlight: Bool
    package let upstreams: [ProxyUpstreamDebugSnapshot]
    package let recentTraffic: [ProxyDebugTrafficEvent]

    package init(
        generatedAt: Date,
        proxyInitialized: Bool,
        cachedToolsListAvailable: Bool,
        warmupInFlight: Bool,
        upstreams: [ProxyUpstreamDebugSnapshot],
        recentTraffic: [ProxyDebugTrafficEvent]
    ) {
        self.generatedAt = generatedAt
        self.proxyInitialized = proxyInitialized
        self.cachedToolsListAvailable = cachedToolsListAvailable
        self.warmupInFlight = warmupInFlight
        self.upstreams = upstreams
        self.recentTraffic = recentTraffic
    }
}
