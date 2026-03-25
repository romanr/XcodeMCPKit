import Foundation
import NIO
import ProxyRuntime

package struct HTTPDebugSnapshot: Codable, Sendable {
    package let generatedAt: Date
    package let proxyInitialized: Bool
    package let cachedToolsListAvailable: Bool
    package let warmupInFlight: Bool
    package let upstreams: [ProxyUpstreamDebugSnapshot]
    package let recentTraffic: [ProxyDebugTrafficEvent]
    package let sessions: [SessionDebugSnapshot]
    package let leases: [RequestLeaseDebugSnapshot]
    package let queuedRequestCount: Int
    
    package init(base: ProxyDebugSnapshot) {
        self.generatedAt = base.generatedAt
        self.proxyInitialized = base.proxyInitialized
        self.cachedToolsListAvailable = base.cachedToolsListAvailable
        self.warmupInFlight = base.warmupInFlight
        self.upstreams = base.upstreams
        self.recentTraffic = base.recentTraffic
        self.sessions = base.sessions
        self.leases = base.leases
        self.queuedRequestCount = base.queuedRequestCount
    }
}

package struct HTTPSSEOpenResult {
    package let bufferedNotifications: [Data]

    package init(bufferedNotifications: [Data]) {
        self.bufferedNotifications = bufferedNotifications
    }
}

package final class HTTPControlService: Sendable {
    private let runtimeCoordinator: any RuntimeCoordinating

    package init(runtimeCoordinator: any RuntimeCoordinating) {
        self.runtimeCoordinator = runtimeCoordinator
    }

    package func debugSnapshotData(includeSensitiveDebugPayloads: Bool = false) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(
            HTTPDebugSnapshot(
                base: runtimeCoordinator.debugSnapshot(
                    includeSensitiveDebugPayloads: includeSensitiveDebugPayloads
                )
            )
        )
    }

    package func openSSE(sessionID: String, channel: Channel) -> HTTPSSEOpenResult {
        let session = runtimeCoordinator.session(id: sessionID)
        let hadClients = session.notificationHub.hasSseClients
        session.notificationHub.addSse(channel)
        let bufferedNotifications = hadClients ? [] : session.router.drainBufferedNotifications()
        return HTTPSSEOpenResult(bufferedNotifications: bufferedNotifications)
    }

    package func closeSSE(sessionID: String, channel: Channel) {
        guard runtimeCoordinator.hasSession(id: sessionID) else { return }
        let session = runtimeCoordinator.session(id: sessionID)
        session.notificationHub.removeSse(channel)
    }

    package func deleteSession(id sessionID: String) {
        guard runtimeCoordinator.hasSession(id: sessionID) else { return }
        runtimeCoordinator.removeSession(id: sessionID)
    }

    package func hasSession(id sessionID: String) -> Bool {
        runtimeCoordinator.hasSession(id: sessionID)
    }

    package func debugReset(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        runtimeCoordinator.debugReset()
        return eventLoop.makeSucceededFuture(())
    }
}
