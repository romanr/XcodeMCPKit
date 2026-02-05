import Foundation
import NIO
import NIOConcurrencyHelpers

final class NotificationHub: Sendable {
    private struct State: Sendable {
        var stdioWriter: StdioWriter?
    }

    private let state = NIOLockedValueBox(State())
    private let sseHub = SSEHub()

    var hasClients: Bool {
        hasSseClients || hasStdioWriter
    }

    var hasSseClients: Bool {
        sseHub.hasClients
    }

    private var hasStdioWriter: Bool {
        state.withLockedValue { $0.stdioWriter != nil }
    }

    func addSse(_ channel: Channel) {
        sseHub.add(channel)
    }

    func removeSse(_ channel: Channel) {
        sseHub.remove(channel)
    }

    func attachStdioWriter(_ writer: StdioWriter) {
        state.withLockedValue { state in
            state.stdioWriter = writer
        }
    }

    func detachStdioWriter() {
        state.withLockedValue { state in
            state.stdioWriter = nil
        }
    }

    func broadcast(_ data: Data) {
        sseHub.broadcast(data)
        let writer = state.withLockedValue { $0.stdioWriter }
        guard let writer else { return }
        Task {
            await writer.send(data)
        }
    }

    func closeAll() {
        sseHub.closeAll()
        detachStdioWriter()
    }
}
