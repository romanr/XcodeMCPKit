import Foundation
import NIO
import ProxyRuntime

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

    package func debugSnapshotData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(runtimeCoordinator.debugSnapshot())
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
}
