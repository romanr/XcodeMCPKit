import Foundation
import NIO
import NIOHTTP1
import NIOConcurrencyHelpers

final class SSEHub: @unchecked Sendable {
    private let lock = NIOLock()
    private var clients: [ObjectIdentifier: Channel] = [:]

    var hasClients: Bool {
        lock.withLock { !clients.isEmpty }
    }

    func add(_ channel: Channel) {
        lock.withLock {
            clients[ObjectIdentifier(channel)] = channel
        }
    }

    func remove(_ channel: Channel) {
        _ = lock.withLock {
            clients.removeValue(forKey: ObjectIdentifier(channel))
        }
    }

    func broadcast(_ data: Data) {
        let payload = "data: \(String(decoding: data, as: UTF8.self))\n\n"
        let channels = lock.withLock { Array(clients.values) }
        for channel in channels {
            channel.eventLoop.execute {
                guard channel.isActive else { return }
                var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
                buffer.writeString(payload)
                _ = channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
            }
        }
    }
}
