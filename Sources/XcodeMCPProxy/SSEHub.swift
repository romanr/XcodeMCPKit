import Foundation
import NIO
import NIOHTTP1
import NIOConcurrencyHelpers

final class SSEHub: Sendable {
    private struct State: Sendable {
        var clients: [ObjectIdentifier: Channel] = [:]
    }

    private let state = NIOLockedValueBox(State())

    var hasClients: Bool {
        state.withLockedValue { !$0.clients.isEmpty }
    }

    func add(_ channel: Channel) {
        state.withLockedValue { state in
            state.clients[ObjectIdentifier(channel)] = channel
        }
    }

    func remove(_ channel: Channel) {
        _ = state.withLockedValue { state in
            state.clients.removeValue(forKey: ObjectIdentifier(channel))
        }
    }

    func broadcast(_ data: Data) {
        let payload = "data: \(String(decoding: data, as: UTF8.self))\n\n"
        let channels = state.withLockedValue { Array($0.clients.values) }
        for channel in channels {
            channel.eventLoop.execute {
                guard channel.isActive else { return }
                var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
                buffer.writeString(payload)
                _ = channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
            }
        }
    }

    func closeAll() {
        let channels = state.withLockedValue { Array($0.clients.values) }
        state.withLockedValue { $0.clients.removeAll() }
        for channel in channels {
            channel.eventLoop.execute {
                channel.close(promise: nil)
            }
        }
    }
}
