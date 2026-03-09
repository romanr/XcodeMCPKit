import Foundation

struct ProxyDebugEvent: Codable, Sendable {
    let timestamp: Date
    let message: String
}

struct ProxyDebugTrafficEvent: Codable, Sendable {
    let timestamp: Date
    let upstreamIndex: Int
    let direction: String
    let bytes: Int
    let preview: String
}

struct ProxyUpstreamDebugSnapshot: Codable, Sendable {
    let upstreamIndex: Int
    let isInitialized: Bool
    let initInFlight: Bool
    let didSendInitialized: Bool
    let healthState: String
    let consecutiveRequestTimeouts: Int
    let consecutiveToolsListFailures: Int
    let lastToolsListSuccessUptimeNs: UInt64?
    let recentStderr: [ProxyDebugEvent]
    let lastDecodeError: ProxyDebugEvent?
    let lastBridgeError: ProxyDebugEvent?
    let resyncCount: Int
    let lastResyncAt: Date?
    let lastResyncDroppedBytes: Int?
    let lastResyncPreview: String?
    let bufferedStdoutBytes: Int
}

struct ProxyDebugSnapshot: Codable, Sendable {
    let generatedAt: Date
    let proxyInitialized: Bool
    let cachedToolsListAvailable: Bool
    let warmupInFlight: Bool
    let upstreams: [ProxyUpstreamDebugSnapshot]
    let recentTraffic: [ProxyDebugTrafficEvent]
}
